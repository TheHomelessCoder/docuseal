# frozen_string_literal: true

# Bennett Legal launcher: check the Bennett source invariants and the database,
# queue and key configuration before ANY service starts.
require 'uri'
require 'json'
require 'open3'

def emit(event, status = nil)
  puts({ service: 'docuseal', event: event, status: status }.compact.to_json)
  $stdout.flush
end

# Local rehearsal is NOT an exemption from the source check.
begin
  require_relative 'source_check'
  BennettSourceCheck.verify!('/app')
rescue StandardError, LoadError
  emit('source_check_rejected')
  exit 78
end

CONTAINER_NAME = /\A[a-z][a-z0-9-]{0,62}\z/

unless ENV['LOCAL_REHEARSAL'] == 'true'
  begin
    url = URI.parse(ENV.fetch('DATABASE_URL'))
    pairs = URI.decode_www_form(url.query.to_s)
    query = pairs.to_h
    # libpq query keywords can override the URI's authority. Also reject the
    # upstream DATABASE_HOST branch, which takes precedence over DATABASE_URL.
    raise 'ambiguous database configuration' unless pairs.length == query.length &&
      (query.keys - %w[sslmode sslrootcert connect_timeout]).empty? &&
      %w[DATABASE_HOST DATABASE_PORT DATABASE_USER DATABASE_PASSWORD DATABASE_NAME].none? { |key| !ENV[key].to_s.empty? }
    raise 'invalid database endpoint' unless url.scheme == 'postgresql' &&
      url.host == ENV.fetch('EXPECTED_DATABASE_HOST') &&
      !url.user.to_s.empty? && url.path == '/docuseal' &&
      (url.port.nil? || url.port == 5432) && url.fragment.nil?
    if ENV['DOCUSEAL_DATABASE_MODE'] == 'host-container'
      # Co-hosted: PostgreSQL is a sibling container on an internal-only Docker
      # network, so traffic never leaves the machine. Accept only a single-label
      # service name (never a DNS name that could resolve off-host) and an
      # explicit sslmode=disable.
      raise 'invalid container database' unless url.host.match?(CONTAINER_NAME) &&
        query['sslmode'] == 'disable' && !query.key?('sslrootcert')
    else
      raise 'invalid database TLS' unless query['sslmode'] == 'verify-full' &&
        query['sslrootcert'] == '/etc/docuseal/rds-global-bundle.pem'
    end
    raise 'invalid database timeout' if query.key?('connect_timeout') && !query['connect_timeout'].match?(/\A(?:[1-9]|1[0-5])\z/)
    ENV['PGCONNECT_TIMEOUT'] = '5'
    raise 'missing stable encryption key' if ENV.fetch('ENCRYPTION_SECRET').length < 64
    raise 'missing stable session key' if ENV.fetch('SECRET_KEY_BASE').length < 64
  rescue StandardError
    emit('configuration_rejected')
    exit 78
  end
end

# The external persistent Redis sidecar prevents the upstream ephemeral Redis plugin.
# ECS runs Redis in the same task (loopback); the co-hosted stack names its
# sibling container. Either way it is never a DNS name that could leave the host.
if ENV['REDIS_PASSWORD']
  redis_host = ENV.fetch('REDIS_HOST', '127.0.0.1')
  unless redis_host == '127.0.0.1' || redis_host.match?(CONTAINER_NAME)
    emit('configuration_rejected')
    exit 78
  end
  password = URI.encode_www_form_component(ENV.fetch('REDIS_PASSWORD'))
  ENV['REDIS_URL'] = "redis://default:#{password}@#{redis_host}:6379/0"
end

# Upstream custom logs contain partial capability tokens and exception payloads.
# Suppress all raw output; container health, the gateway and JUD job receipts diagnose health.
emit('starting')
Open3.popen2e('/app/bin/bundle', 'exec', 'puma', '-C', '/opt/docuseal/puma.rb',
             '--dir', '/app') do |stdin, output, process|
  stdin.close
  %w[TERM INT].each { |signal| Signal.trap(signal) { Process.kill(signal, process.pid) rescue nil } }
  output.each_line { |_line| nil }
  result = process.value
  emit('exited', result.exitstatus || 128 + result.termsig)
  exit(result.exitstatus || 128 + result.termsig)
end
