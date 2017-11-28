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
    # In the event minimum required configuration is not found an exception
    # will be raised.
    if (options['host'] && options['port'])
      connection = Net::HTTP.new(options['host'], options['port'])
    else
      raise "[hiera-consul]: Missing minimum configuration, please check hiera.yaml"
    end

    # Cache relevant information and the Net::HTTP connection object. Because
    # we pass context around to most function calls, not options, we'll cache
    # options as well.. The context and cache is state data.
    # (clk == consul lookup key)
    context.cache(:clk_options, options) unless context.cache_has_key(:clk_options)
    context.cache(:clk_connection, connection(context)) unless context.cache_has_key(:clk_connection)

    # Begin the lookup.
    connection = context.cached_value(:clk_connection)
    pathkey = "#{options['path']}/#{key}"

    # Validate the path and key being asked for
    if options['path'] !~ /^\/v\d\/(catalog|kv)\//
      Puppet.debug("[hiera-consul]: We only support queries to catalog and kv and you asked #{options['path']}, skipping")
      return context.not_found()
    end

    if pathkey.match("//")
      Puppet.debug("[hiera-consul]: The specified path #{pathkey} is malformed, skipping")
      return context.not_found()
    end

    # Query consul for the path/key value
    result = query_consul(pathkey, context)

    # Either cache and return the result, or indicate not_found(). The
    # query_consul function returns nil if no value was found in consul.
    # Because of this implementation decision, the consul backend cannot at
    # this time cannot store a literal nil.
    result.nil? ? context.not_found() : context.cache(key, result)
  end

  def connection(context)
    options = context.cached_value(:clk_options)

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

  def query_consul(path, context)
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

  # WHAT IS THIS FOR???
  # def build_cache!
  #   services = query_consul('/v1/catalog/services')
  #   return nil unless services.is_a? Hash
  #   services.each do |key, value|
  #     service = query_consul("/v1/catalog/service/#{key}")
  #     next unless service.is_a? Array
  #     service.each do |node_hash|
  #       node = node_hash['Node']
  #       node_hash.each do |property, value|
  #         # Value of a particular node
  #         next if property == 'ServiceID'
  #         unless property == 'Node'
  #           @cache["#{key}_#{property}_#{node}"] = value
  #         end
  #         unless @cache.has_key?("#{key}_#{property}")
  #           # Value of the first registered node
  #           @cache["#{key}_#{property}"] = value
  #           # Values of all nodes
  #           @cache["#{key}_#{property}_array"] = [value]
  #         else
  #           @cache["#{key}_#{property}_array"].push(value)
  #         end
  #       end
  #     end
  #   end
  #   Puppet.debug("[hiera-consul]: Cache #{@cache}")
  # end

end
