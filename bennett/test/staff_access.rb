# frozen_string_literal: true

# Real JWT cryptography, without Rails, a database or external services.
# Run with the image's bundle: bundle exec ruby bennett/test/staff_access.rb
require 'minitest/autorun'
require_relative '../../lib/bennett/staff_access' unless defined?(Bennett::StaffAccess)

class StaffAccessTest < Minitest::Test
  KEY = OpenSSL::PKey::RSA.generate(2048)
  JWK = JWT::JWK.new(KEY, 'staff-key')
  AUDIENCE = 'a' * 64

  def setup
    @fetches = 0
    @verifier = Bennett::StaffAccess::Verifier.new(team: 'bennett-test', audience: AUDIENCE, fetch_keys: lambda {
      @fetches += 1
      { 'keys' => [JSON.parse(JWK.export.to_json)] }
    })
  end

  def token(**changes)
    claims = { iss: 'https://bennett-test.cloudflareaccess.com', aud: [AUDIENCE],
               iat: Time.now.to_i, exp: Time.now.to_i + 300, sub: 'staff-identity',
               email: 'Stephen@example.test', type: 'app' }.merge(changes)
    JWT.encode(claims, KEY, 'RS256', kid: JWK.kid)
  end

  def test_existing_human_identity_and_cached_keys
    3.times { assert_equal 'stephen@example.test', @verifier.email(token) }
    assert_equal 1, @fetches
  end

  def test_untrusted_time_issuer_audience_and_nonhuman_claims
    [{ exp: Time.now.to_i - 1 }, { iat: Time.now.to_i + 60 }, { iss: 'https://attacker.test' },
     { aud: ['api-application'] }, { aud: [] }, { type: 'org' }, { sub: '' },
     { email: nil }, { email: '' }, { email: ' stephen@example.test' },
     { email: "stephen@example.test\n" }, { email: 'a' * 255 }].each do |changes|
      assert_nil @verifier.email(token(**changes)), changes.keys.inspect
    end
  end

  def test_signature_and_algorithm_confusion_are_refused
    other = OpenSSL::PKey::RSA.generate(2048)
    claims, = JWT.decode(token, nil, false)
    assert_nil @verifier.email(JWT.encode(claims, other, 'RS256', kid: JWK.kid))
    assert_nil @verifier.email(JWT.encode(claims, KEY.public_key.to_pem, 'HS256', kid: JWK.kid))
    assert_nil @verifier.email(JWT.encode(claims, nil, 'none', kid: JWK.kid))
    assert_nil @verifier.email('not.a.token')
    assert_nil @verifier.email(nil)
    assert_nil @verifier.email('a' * 16_385)
  end

  def test_unknown_keys_do_not_create_unbounded_certificate_fetches
    claims, = JWT.decode(token, nil, false)
    10.times do |index|
      assert_nil @verifier.email(JWT.encode(claims, KEY, 'RS256', kid: "unknown-#{index}"))
    end
    assert_equal 1, @fetches
    assert_equal 'stephen@example.test', @verifier.email(token)
  end

  def test_key_service_errors_and_malformed_key_sets_fail_closed
    [nil, [], {}, { 'keys' => [] }, { 'keys' => 'wrong' },
     { 'keys' => [{ 'kty' => 'oct', 'kid' => JWK.kid }] }].each do |keys|
      verifier = Bennett::StaffAccess::Verifier.new(team: 'bennett-test', audience: AUDIENCE, fetch_keys: -> { keys })
      assert_nil verifier.email(token)
    end
    verifier = Bennett::StaffAccess::Verifier.new(team: 'bennett-test', audience: AUDIENCE, fetch_keys: lambda {
      raise IOError
    })
    assert_nil verifier.email(token)
  end
end
