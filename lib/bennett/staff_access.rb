# frozen_string_literal: true

require 'json'
require 'jwt'
require 'net/http'

module Bennett
  # Authenticate a human Access application token, never an email header or a
  # JUD/API token. Account enrollment and permissions remain DocuSeal's own.
  module StaffAccess
    Denied = Class.new(StandardError)
    ConfigurationError = Class.new(StandardError)
    Configuration = Data.define(:host, :team, :audience)

    module_function

    def enabled?
      ENV['BENNETT_STAFF_ACCESS_ENABLED'] == 'true'
    end

    def configuration
      host = ENV.fetch('BENNETT_STAFF_ACCESS_HOST', '')
      team = ENV.fetch('BENNETT_STAFF_ACCESS_TEAM', '')
      audience = ENV.fetch('BENNETT_STAFF_ACCESS_AUD', '')
      unless host.match?(/\A[a-z0-9][a-z0-9.-]+\.[a-z]{2,}\z/) &&
             team.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) && audience.match?(/\A[a-f0-9]{64}\z/)
        raise ConfigurationError, 'Staff Access host, team and application audience are required'
      end

      Configuration.new(host:, team:, audience:)
    end

    def verifier
      config = configuration
      @verifier = Verifier.new(team: config.team, audience: config.audience) if @verifier_config != config
      @verifier_config = config
      @verifier
    end

    class Verifier
      MAX_TOKEN_BYTES = 16_384
      KEY_TTL = 300
      KEY_REFRESH_INTERVAL = 60

      def initialize(team:, audience:, fetch_keys: nil)
        @issuer = "https://#{team}.cloudflareaccess.com"
        @audience = audience
        @fetch_keys = fetch_keys || method(:fetch_keys)
        @lock = Mutex.new
        @keys = []
        @fetched_at = -Float::INFINITY
      end

      def email(token)
        return unless token.is_a?(String) && token.bytesize.between?(1, MAX_TOKEN_BYTES)

        claims, = JWT.decode(token, nil, true, algorithms: ['RS256'],
                                               verify_iss: true, iss: @issuer, verify_aud: true, aud: @audience,
                                               verify_iat: true,
                                               required_claims: %w[exp iat iss aud sub email type]) do |header|
          key_for(header)
        end
        return unless claims['type'] == 'app' && claims['sub'].is_a?(String) && !claims['sub'].empty?
        return unless claims['iat'].is_a?(Integer) && claims['exp'].is_a?(Integer)

        email = claims['email']
        return unless email.is_a?(String) && email.bytesize <= 254 &&
                      email.match?(/\A[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z/)

        email.downcase
      rescue JWT::DecodeError, JSON::ParserError, IOError, SystemCallError, Timeout::Error,
             Net::HTTPError, OpenSSL::OpenSSLError, ArgumentError, TypeError, KeyError
        # Never include assertions, provider responses or exception messages.
        nil
      end

      private

      def key_for(header)
        raise JWT::DecodeError, 'Invalid key selector' unless header['alg'] == 'RS256' &&
                                                              header['kid'].is_a?(String) &&
                                                              header['kid'].bytesize.between?(1, 256)

        @lock.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          refresh_keys(now) if now - @fetched_at >= KEY_TTL
          key = @keys.find { |item| item['kid'] == header['kid'] }
          if !key && now - @fetched_at >= KEY_REFRESH_INTERVAL
            refresh_keys(now)
            key = @keys.find { |item| item['kid'] == header['kid'] }
          end
          raise JWT::DecodeError, 'Unknown signing key' unless key

          JWT::JWK.import(key).public_key
        end
      end

      def refresh_keys(now)
        # Bound failed and unknown-kid refreshes too; untrusted tokens cannot
        # force one network request per request or make expired keys permanent.
        @fetched_at = now
        @keys = []
        response = @fetch_keys.call
        raise JWT::DecodeError, 'Invalid key response' unless response.is_a?(Hash)

        keys = response['keys']
        raise JWT::DecodeError, 'Invalid key set' unless keys.is_a?(Array) && keys.length.between?(1, 20)

        @keys = keys.select do |key|
          key.is_a?(Hash) && key['kty'] == 'RSA' &&
            (key['use'].nil? || key['use'] == 'sig') &&
            (key['alg'].nil? || key['alg'] == 'RS256')
        end
      end

      def fetch_keys
        uri = URI("#{@issuer}/cdn-cgi/access/certs")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 2
        http.read_timeout = 2
        body = +''
        http.start do
          http.request(Net::HTTP::Get.new(uri)) do |response|
            raise JWT::DecodeError, 'Key service unavailable' unless response.is_a?(Net::HTTPSuccess)

            response.read_body do |chunk|
              body << chunk
              raise JWT::DecodeError, 'Key response too large' if body.bytesize > 65_536
            end
          end
        end
        JSON.parse(body)
      end
    end
  end
end
