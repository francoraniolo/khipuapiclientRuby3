require 'date'
require 'json'
require 'logger'
require 'tempfile'
require 'typhoeus'
require 'uri'
require 'net/http'
require 'openssl'
require 'base64'

module Khipu
  class ApiClient

    attr_accessor :host

    # Defines the headers to be used in HTTP requests of all API calls by default.
    #
    # @return [Hash]
    attr_accessor :default_headers

    # Stores the HTTP response from the last API call using this API client.
    attr_accessor :last_response

    def initialize(host = nil)
      @host = host || Configuration.base_url
      @format = 'json'
      @user_agent = "khipu-api-ruby-client/#{VERSION}" + "|" + (Configuration.platform || '') + "/" + (Configuration.platform_version || '')
      @default_headers = {
        'Content-Type' => "application/#{@format.downcase}",
        'User-Agent' => @user_agent
      }
    end

    def call_api(http_method, path, opts = {})
      request = build_request(http_method, path, opts)
      response = request.run

      # record as last response
      @last_response = response

      if Configuration.debugging
        Configuration.logger.debug "HTTP response body ~BEGIN~\n#{response.body}\n~END~\n"
      end

      unless response.success?
        fail ApiError.new(:code => response.code,
                          :response_headers => response.headers,
                          :response_body => response.body),
             response.status_message
      end

      if opts[:return_type]
        deserialize(response, opts[:return_type])
      else
        nil
      end
    end

    def build_request(http_method, path, opts = {})
      url = build_request_url(path)
      http_method = http_method.to_sym.downcase

      header_params = @default_headers.merge(opts[:header_params] || {})
      query_params = opts[:query_params] || {}
      form_params = opts[:form_params] || {}

      
      update_params_for_auth! @host, path, http_method, header_params, query_params, form_params, opts[:auth_names], opts[:body]
      

      req_opts = {
        :method => http_method,
        :headers => header_params,
        :params => query_params,
        :ssl_verifypeer => Configuration.verify_ssl,
        :sslcert => Configuration.cert_file,
        :sslkey => Configuration.key_file,
        :cainfo => Configuration.ssl_ca_cert,
        :verbose => Configuration.debugging
      }

      if [:post, :patch, :put, :delete].include?(http_method)
        req_body = build_request_body(header_params, form_params, opts[:body])
        req_opts.update :body => req_body
        if Configuration.debugging
          Configuration.logger.debug "HTTP request body param ~BEGIN~\n#{req_body}\n~END~\n"
        end
      end

      Typhoeus::Request.new(url, req_opts)
    end

    # Deserialize the response to the given return type.
    #
    # @param [String] return_type some examples: "User", "Array[User]", "Hash[String,Integer]"
    def deserialize(response, return_type)
      body = response.body
      return nil if body.nil? || body.empty?

      # handle file downloading - save response body into a tmp file and return the File instance
      return download_file(response) if return_type == 'File'

      # ensuring a default content type
      content_type = response.headers['Content-Type'] || 'application/json'

      unless content_type.start_with?('application/json')
        fail "Content-Type is not supported: #{content_type}"
      end

      begin
        data = JSON.parse("[#{body}]", :symbolize_names => true)[0]
      rescue JSON::ParserError => e
        if %w(String Date DateTime).include?(return_type)
          data = body
        else
          raise e
        end
      end

      convert_to_type data, return_type
    end

    # Convert data to the given return type.
    def convert_to_type(data, return_type)
      return nil if data.nil?
      case return_type
      when 'String'
        data.to_s
      when 'Integer'
        data.to_i
      when 'Float'
        data.to_f
      when 'BOOLEAN'
        data == true
      when 'DateTime'
        # parse date time (expecting ISO 8601 format)
        DateTime.parse data
      when 'Date'
        # parse date time (expecting ISO 8601 format)
        Date.parse data
      when 'Object'
        # generic object, return directly
        data
      when /\AArray<(.+)>\z/
        # e.g. Array<Pet>
        sub_type = $1
        data.map {|item| convert_to_type(item, sub_type) }
      when /\AHash\<String, (.+)\>\z/
        # e.g. Hash<String, Integer>
        sub_type = $1
        {}.tap do |hash|
          data.each {|k, v| hash[k] = convert_to_type(v, sub_type) }
        end
      else
        # models, e.g. Pet
        Khipu.const_get(return_type).new.tap do |model|
          model.build_from_hash data
        end
      end
    end

    # Save response body into a file in (the defined) temporary folder, using the filename
    # from the "Content-Disposition" header if provided, otherwise a random filename.
    #
    # @see Configuration#temp_folder_path
    # @return [File] the file downloaded
    def download_file(response)
      tmp_file = Tempfile.new '', Configuration.temp_folder_path
      content_disposition = response.headers['Content-Disposition']
      if content_disposition
        filename = content_disposition[/filename=['"]?([^'"\s]+)['"]?/, 1]
        path = File.join File.dirname(tmp_file), filename
      else
        path = tmp_file.path
      end
      # close and delete temp file
      tmp_file.close!

      File.open(path, 'w') { |file| file.write(response.body) }
      Configuration.logger.info "File written to #{path}. Please move the file to a proper "\
                                "folder for further processing and delete the temp afterwards"
      File.new(path)
    end

    def build_request_url(path)
      # Add leading and trailing slashes to path
      path = "/#{path}".gsub(/\/+/, '/')
      URI::DEFAULT_PARSER.escape(host + path)
    end

    def build_request_body(header_params, form_params, body)
      # http form
      if header_params['Content-Type'] == 'application/x-www-form-urlencoded' ||
          header_params['Content-Type'] == 'multipart/form-data'
        data = form_params.dup
        data.each do |key, value|
          data[key] = value.to_s if value && !value.is_a?(File)
        end
      elsif body
        data = body.is_a?(String) ? body : body.to_json
      else
        data = nil
      end
      data
    end

    def percent_encode(v)
      return URI::DEFAULT_PARSER.escape(v.to_s.to_str, /[^a-zA-Z0-9\-\.\_\~]/)
    end

    # Update hearder and query params based on authentication settings.
    def update_params_for_auth!(host, path, http_method, header_params, query_params, form_params, auth_names, body)
      Array(auth_names).each do |auth_name|
        if auth_name == "khipu"
          params = query_params.merge(form_params)

          encoded = {}
          params.each do |k, v|
            encoded[percent_encode(k)] = percent_encode(v)
          end

          to_sign = http_method.to_s.upcase + "&" + percent_encode(host + path)

          encoded.keys.sort.each do |key|
            to_sign += "&#{key}=" + encoded[key]
          end
          if !body.nil? && header_params['Content-Type']=='application/json'
             to_sign += "&" + body
          end
          if Configuration.debugging
            Configuration.logger.debug "encoded params: #{encoded}"
            Configuration.logger.debug "string to sign: #{to_sign}"
          end

          hash = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), Configuration.secret, to_sign)
          header_params['Authorization'] = Configuration.receiver_id.to_s + ":" + hash

          next
        end
        auth_setting = Configuration.auth_settings[auth_name]
        next unless auth_setting
        case auth_setting[:in]
        when 'header' then header_params[auth_setting[:key]] = auth_setting[:value]
        when 'query'  then query_params[auth_setting[:key]] = auth_setting[:value]
        else fail ArgumentError, 'Authentication token must be in `query` of `header`'
        end
      end
    end

    def user_agent=(user_agent)
      @user_agent = user_agent
      @default_headers['User-Agent'] = @user_agent
    end


    # Return Accept header based on an array of accepts provided.
    # @param [Array] accepts array for Accept
    # @return [String] the Accept header (e.g. application/json)
    def select_header_accept(accepts)
      if accepts.empty?
        return
      elsif accepts.any?{ |s| s.casecmp('application/json') == 0 }
        'application/json' # look for json data by default
      else
        accepts.join(',')
      end
    end

    # Return Content-Type header based on an array of content types provided.
    # @param [Array] content_types array for Content-Type
    # @return [String] the Content-Type header  (e.g. application/json)
    def select_header_content_type(content_types)
      if content_types.empty?
        'application/json' # use application/json by default
      elsif content_types.any?{ |s| s.casecmp('application/json')==0 }
        'application/json' # use application/json if it's included
      else
        content_types[0] # otherwise, use the first one
      end
    end

    # Convert object (array, hash, object, etc) to JSON string.
    # @param [Object] model object to be converted into JSON string
    # @return [String] JSON string representation of the object
    def object_to_http_body(model)
      return if model.nil?
      _body = nil
      if model.is_a?(Array)
        _body = model.map{|m| object_to_hash(m) }
      else
        _body = object_to_hash(model)
      end
      _body.to_json
    end

    # Convert object(non-array) to hash.
    # @param [Object] obj object to be converted into JSON string
    # @return [String] JSON string representation of the object
    def object_to_hash(obj)
      if obj.respond_to?(:to_hash)
        obj.to_hash
      else
        obj
      end
    end
  end
end
