require 'net/http'
require 'net/https'
require 'json'
require 'base64'

Puppet::Functions.create_function(:consul_lookup_key) do

  dispatch :consul_lookup_key do
    param 'String[1]', :key
    param 'Hash[String[1],Any]', :options
    param 'Puppet::LookupContext', :context
  end

  def consul_lookup_key(key, options, context)
    return context.cached_value(key) if context.cache_has_key(key)

    # Check for minimum required configuration before attempting any lookups.
    # In the event minimum required configuration is not found, an exception
    # will be raised.
    validate_options(options)

    # Cache relevant information and the Net::HTTP connection object. Because
    # we pass context around to most function calls, not options, we'll cache
    # options as well. The context and cache is state data.
    # (clk == consul lookup key)
    context.cache(:clk_options, options) unless context.cache_has_key(:clk_options)
    context.cache(:clk_connection, connection(options)) unless context.cache_has_key(:clk_connection)

    # Begin the lookup.
    connection = context.cached_value(:clk_connection)

    options['endpoints'].each do |endpoint|
      # Special case for "services" path
      if endpoint == 'services'
        cache_services!(context) unless context.cache_has_key(:clk_services)
        return context.cached_value(key) if context.cache_has_key(key)
      end

      next unless valid_endpoint?(endpoint)
      next unless valid_key?(key)

      result = query_consul(endpoint, key, context)

      return context.cache(key, result) unless result.nil?
    end

    # If we got this far, we didn't find a result
    context.not_found()
  end

  def validate_options(options)
    unless options.key?('uri') &&
           options.key?('endpoints')
      raise "[hiera-consul]: Missing minimum configuration, please check hiera.yaml"
    end
  end

  def valid_endpoint?(endpoint)
    if endpoint !~ /^\/v\d\/(catalog|kv)\//
      Puppet.debug("[hiera-consul]: We only support queries to catalog and kv and you queried #{endpoint}, skipping")
      false
    else
      true
    end
  end

  def valid_key?(key)
    if key.match("//")
      Puppet.debug("[hiera-consul]: The specified key #{key} is malformed, skipping")
      false
    else
      true
    end
  end

  def connection(options)
    connection.read_timeout = options['http_read_timeout'] || 10
    connection.open_timeout = options['http_connect_timeout'] || 10

    if options['use_ssl']
      connection.use_ssl = true

      if options['ssl_verify'] == false
        connection.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        connection.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      if options['ssl_cert']
        store = OpenSSL::X509::Store.new
        store.add_cert(OpenSSL::X509::Certificate.new(File.read(options['ssl_ca_cert'])))
        connection.cert_store = store

        connection.key = OpenSSL::PKey::RSA.new(File.read(options['ssl_key']))
        connection.cert = OpenSSL::X509::Certificate.new(File.read(options['ssl_cert']))
      end
    else
      connection.use_ssl = false
    end

    connection
  end

  def token(path, context)
    options = context.cached_value(:clk_options)
    # Token is passed only when querying kv store
    if options['token'] and path =~ /^\/v\d\/kv\//
      return "?token=#{options['token']}"
    else
      return nil
    end
  end

  def query_consul(endpoint, key, context)
    path = "#{endpoint}/#{key}"
    consul = context.cached_value(:clk_connection)
    options = context.cached_value(:clk_options)

    httpreq = Net::HTTP::Get.new("#{path}#{token(path, context)}")
    answer = nil
    begin
      result = consul.request(httpreq)
    rescue Exception => e
      Puppet.debug("[hiera-consul]: Could not connect to Consul")
      raise Exception, e.message unless options['failure'] == 'graceful'
      return answer
    end
    unless result.kind_of?(Net::HTTPSuccess)
      Puppet.debug("[hiera-consul]: HTTP response code was #{result.code}")
      return answer
    end
    Puppet.debug("[hiera-consul]: Answer was #{result.body}")
    answer = parse_result(result.body)
    return answer
  end

  def parse_result(res)
    answer = nil
    if res == "null"
      Puppet.debug("[hiera-consul]: Jumped as consul null is not valid")
      return answer
    end
    # Consul always returns an array
    res_array = JSON.parse(res)
    # See if we are a k/v return or a catalog return
    if res_array.length > 0
      if res_array.first.include? 'Value'
        if res_array.first['Value'] == nil
          # The Value is nil so we return it directly without trying to decode it ( which would fail )
          return answer
        else
          answer = Base64.decode64(res_array.first['Value'])
        end
      else
        answer = res_array
      end
    else
      Puppet.debug("[hiera-consul]: Jumped as array empty")
    end
    return answer
  end

  def cache_services!(context)
    services = query_consul('/v1/catalog/services')
    return nil unless services.is_a? Hash
    services.each do |key, value|
      service = query_consul("/v1/catalog/service/#{key}")
      next unless service.is_a? Array
      service.each do |node_hash|
        node = node_hash['Node']
        node_hash.each do |property, value|
          # Value of a particular node
          next if property == 'ServiceID'
          unless property == 'Node'
            context.cache("#{key}_#{property}_#{node}", value)
          end
          unless context.cache_has_key("#{key}_#{property}")
            # Value of the first registered node
            context.cache("#{key}_#{property}", value)
            # Values of all nodes
            context.cache("#{key}_#{property}_array", [value])
          else
            # Add an entry to the existing *_array cache value
            prev_array = context.cached_value("#{key}_#{property}_array")
            new_array = prev_array.push(value)
            context.cache("#{key}_#{property}_array", new_array)
          end
        end
      end
    end
    context.cache(:clk_services, true)
    Puppet.debug("[hiera-consul]: services #{@cache}")
  end

end
