#
# TODO:
#   - Figure out why this works with puppet apply and not puppet agent -t
#   - Look into caching values
#   - Test the options: default_field, default_field_behavior, and default_field_parse
#

Puppet::Functions.create_function(:hiera_vault) do

  begin
    require 'json'
  rescue LoadError => e
    raise Puppet::DataBind::LookupError, "Must install json gem to use hiera-vault"
  end
  begin
    require 'vault'
  rescue LoadError => e
    raise Puppet::DataBind::LookupError, "Must install vault gem to use hiera-vault"
  end

  dispatch :lookup_key do
    param 'Variant[String, Numeric]', :key
    param 'Hash', :options
    param 'Puppet::LookupContext', :context
  end

  def lookup_key(key, options, context)

    if confine_keys = options['confine_to_keys']
      raise ArgumentError, 'confine_to_keys must be an array' unless confine_keys.is_a?(Array)
      confine_keys.map! { |r| Regexp.new(r) }
      regex_key_match = Regexp.union(confine_keys)
      unless key[regex_key_match] == key
        context.explain { "Skipping hiera_vault backend because key does not match confine_to_keys" }
        context.not_found
      end
    end

    result = vault_get(key, options, context)

    return result
  end


  def vault_get(key, options, context)

    options['default_field_behavior'] ||= 'ignore'
    options['default_field_parse']    ||= 'string'
    options['mounts']                 ||= {}
    options['mounts']['generic']      ||= ['/secret']

    if not ['string','json'].include?(options['default_field_parse'])
      Raise ArgumentError, "[hiera-vault] invalid value for default_field_parse: '#{options['default_field_behavior']}', should be one of 'string','json'"
    end

    # :default_field_behavior:
    #   'ignore' => ignore additional fields, if the field is not present return nil
    #   'only'   => only return value of default_field when it is present and the only field, otherwise return hash as normal
    if not ['ignore','only'].include?(options['default_field_behavior'])
      raise Exception, "[hiera-vault] invalid value for default_field_behavior: '#{options['default_field_behavior']}', should be one of 'ignore','only'"
    end

    begin
      vault = Vault::Client.new

      vault.configure do |config|
        config.address = options['address'] unless options['address'].nil?
        config.token = options['token'] unless options['token'].nil?
        config.ssl_pem_file = options['ssl_pem_file'] unless options['ssl_pem_file'].nil?
        config.ssl_verify = options['ssl_verify'] unless options['ssl_verify'].nil?
        config.ssl_ca_cert = options['ssl_ca_cert'] if config.respond_to? :ssl_ca_cert
        config.ssl_ca_path = options['ssl_ca_path'] if config.respond_to? :ssl_ca_path
        config.ssl_ciphers = options['ssl_ciphers'] if config.respond_to? :ssl_ciphers
      end

      fail if vault.sys.seal_status.sealed?

      context.explain { "[hiera-vault] Client configured to connect to #{vault.address}" }
    rescue Exception => e
      vault = nil
      context.explain { "[hiera-vault] Skipping backend. Configuration error: #{e}" }
      context.not_found
    end

    answer = nil
    found = false

    # Only generic mounts supported so far                                                                                                   
    options['mounts']['generic'].each do |mount|
      path = context.interpolate(mount) + key
      context.explain { "[hiera-vault] Looking in path #{path}" }

      begin
        secret = vault.logical.read(path)
      rescue Vault::HTTPConnectionError
        context.explain { "[hiera-vault] Could not connect to read secret: #{path}" }
      rescue Vault::HTTPError => e
        context.explain { "[hiera-vault] Could not read secret #{path}: #{e.errors.join("\n").rstrip}" }
      end

      next if secret.nil?

      context.explain { "[hiera-vault] Read secret: #{key}" }
      if (options['default_field'] and options['default_field_behavior'] == 'ignore') or
         (secret.data.has_key?(options['default_field'].to_sym) and secret.data.length == 1)

        return nil if not secret.data.has_key?(options['default_field'].to_sym)

        new_answer = secret.data[options['default_field'].to_sym]

        if options['default_field_parse'] == 'json'
          begin
            new_answer = JSON.parse(new_answer)
          rescue JSON::ParserError => e
            context.explain { "[hiera-vault] Could not parse string as json: #{e}" }
          end
        end

      else
        # Turn secret's hash keys into strings
        new_answer = secret.data.inject({}) { |h, (k, v)| h[k.to_s] = v; h }
      end

#      context.explain {"[hiera-vault] Data: #{new_answer}:#{new_answer.class}" }

      if ! new_answer.nil?
        answer = new_answer
        break
      end
    end

    return answer
  end
end