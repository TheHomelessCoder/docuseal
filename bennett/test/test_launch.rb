# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tempfile'
require_relative 'helper'

# Exercise the real launch guard, replacing only process creation. No Rails,
# database, network, credential reads or real child service is involved.
class LaunchTest < Minitest::Test
  LAUNCH = BennettTest.path('bennett/launch.rb')

  def setup
    @app = BennettTest.source_copy
  end

  def teardown
    FileUtils.remove_entry_secure(@app)
  end

  def launch(changes = {})
    env = {
      'TEST_APP_ROOT' => @app,
      'DATABASE_URL' => 'postgresql://synthetic:fixture@db.example.test/docuseal?sslmode=verify-full&sslrootcert=/etc/docuseal/rds-global-bundle.pem',
      'EXPECTED_DATABASE_HOST' => 'db.example.test',
      'ENCRYPTION_SECRET' => 'synthetic-encryption-' * 4,
      'SECRET_KEY_BASE' => 'synthetic-session-' * 4
    }.merge(changes)
    Tempfile.create(['launch-stub', '.rb']) do |stub|
      stub.write(<<~RUBY)
        require 'open3'
        require 'uri'
        require #{BennettTest.path('bennett/source_check').inspect}
        module BennettSourceCheck
          class << self
            alias_method :verify_actual_source!, :verify!
            # Remap only the container path; run the actual source check.
            def verify!(root)
              raise 'unexpected app root' unless root == '/app'
              verify_actual_source!(ENV.fetch('TEST_APP_ROOT'))
            end
          end
        end
        module Open3
          def self.popen2e(*)
            if ENV['TEST_EXPECT_REDIS_URL'] && ENV['REDIS_URL'] != ENV['TEST_EXPECT_REDIS_URL']
              exit 79
            end
            # redis-client's URLConfig#password uses this decoder.
            if ENV['TEST_EXPECT_REDIS_PASSWORD'] && URI.decode_www_form_component(URI(ENV['REDIS_URL']).password) != ENV['TEST_EXPECT_REDIS_PASSWORD']
              exit 79
            end
            puts 'synthetic_child_started'
            exit 0
          end
        end
      RUBY
      stub.flush
      Open3.capture3(env, RbConfig.ruby, '-r', stub.path, LAUNCH, unsetenv_others: true)
    end
  end

  def test_missing_unpatched_or_unattributed_source_never_starts_even_locally
    [
      ->(_root) { nil },
      ->(root) { BennettTest.edit(root, 'app/controllers/submit_form_controller.rb') { |text| text.sub(', with_order: true', '') } },
      ->(root) { BennettTest.edit(root, 'app/views/shared/_bennett_signing_masthead.html.erb') { |text| text.sub('Docuseal::PRODUCT_URL', '"#"') } }
    ].each_with_index do |change, index|
      root = BennettTest.source_copy
      change.call(root)
      out, _err, result = launch('LOCAL_REHEARSAL' => 'true', 'TEST_APP_ROOT' => index.zero? ? File.join(root, 'missing') : root)
      assert_equal 78, result.exitstatus, index
      assert_includes out, 'source_check_rejected'
      refute_includes out, 'synthetic_child_started'
    ensure
      FileUtils.remove_entry_secure(root)
    end
  end

  def test_valid_private_verified_database_starts
    out, err, result = launch
    assert_equal 0, result.exitstatus, err
    assert_includes out, 'synthetic_child_started'
  end

  def test_libpq_query_cannot_override_verified_endpoint
    out, _err, result = launch('DATABASE_URL' => 'postgresql://synthetic:fixture@db.example.test/docuseal?sslmode=verify-full&sslrootcert=/etc/docuseal/rds-global-bundle.pem&host=other.example.test')
    assert_equal 78, result.exitstatus
    refute_includes out, 'synthetic_child_started'
    refute_includes out, 'fixture'
  end

  def test_ambiguous_tls_parameters_and_database_host_override_are_rejected
    [
      { 'DATABASE_URL' => 'postgresql://synthetic:fixture@db.example.test/docuseal?sslmode=disable&sslmode=verify-full&sslrootcert=/etc/docuseal/rds-global-bundle.pem' },
      { 'DATABASE_HOST' => 'other.example.test' },
      { 'DATABASE_URL' => 'postgresql://synthetic:fixture@db.example.test/other?sslmode=verify-full&sslrootcert=/etc/docuseal/rds-global-bundle.pem' }
    ].each do |changes|
      _out, _err, result = launch(changes)
      assert_equal 78, result.exitstatus, changes.inspect
    end
  end

  def test_unverified_tls_or_missing_stable_keys_are_rejected
    [{ 'DATABASE_URL' => 'postgresql://synthetic:fixture@db.example.test/docuseal?sslmode=require' },
     { 'ENCRYPTION_SECRET' => '' }, { 'SECRET_KEY_BASE' => '' }].each do |changes|
      out, _err, result = launch(changes)
      assert_equal 78, result.exitstatus, changes.inspect
      assert_includes out, 'configuration_rejected'
    end
  end

  def test_redis_password_round_trips_using_the_client_decoder
    _out, _err, result = launch('REDIS_PASSWORD' => 'synthetic space+/@',
                                'TEST_EXPECT_REDIS_PASSWORD' => 'synthetic space+/@')
    assert_equal 0, result.exitstatus
  end

  def test_local_rehearsal_still_uses_external_sink_and_queue_configuration
    _out, _err, result = launch('LOCAL_REHEARSAL' => 'true', 'DATABASE_URL' => 'postgresql://synthetic:fixture@postgres/docuseal',
                                'REDIS_URL' => 'redis://default:synthetic@redis:6379/0',
                                'TEST_EXPECT_REDIS_URL' => 'redis://default:synthetic@redis:6379/0')
    assert_equal 0, result.exitstatus
  end

  def host_container(changes = {})
    launch({ 'DOCUSEAL_DATABASE_MODE' => 'host-container', 'EXPECTED_DATABASE_HOST' => 'postgres',
             'DATABASE_URL' => 'postgresql://docuseal:fixture@postgres/docuseal?sslmode=disable' }.merge(changes))
  end

  def test_cohosted_container_database_and_queue_start
    out, err, result = host_container('REDIS_PASSWORD' => 'synthetic', 'REDIS_HOST' => 'valkey',
                                      'TEST_EXPECT_REDIS_URL' => 'redis://default:synthetic@valkey:6379/0')
    assert_equal 0, result.exitstatus, err
    assert_includes out, 'synthetic_child_started'
  end

  def test_cohosted_mode_rejects_dns_names_tls_mixups_and_mismatches
    [
      { 'EXPECTED_DATABASE_HOST' => 'db.example.test', 'DATABASE_URL' => 'postgresql://docuseal:fixture@db.example.test/docuseal?sslmode=disable' },
      { 'DATABASE_URL' => 'postgresql://docuseal:fixture@postgres/docuseal' },
      { 'DATABASE_URL' => 'postgresql://docuseal:fixture@postgres/docuseal?sslmode=disable&sslrootcert=/tmp/x' },
      { 'DATABASE_URL' => 'postgresql://docuseal:fixture@other/docuseal?sslmode=disable' },
      { 'DATABASE_URL' => 'postgresql://docuseal:fixture@postgres/docuseal?sslmode=disable&host=evil.example.test' },
      { 'REDIS_PASSWORD' => 'synthetic', 'REDIS_HOST' => 'redis.example.test' },
      { 'ENCRYPTION_SECRET' => 'short' }
    ].each do |changes|
      out, _err, result = host_container(changes)
      assert_equal 78, result.exitstatus, changes.inspect
      refute_includes out, 'synthetic_child_started'
    end
  end

  def test_production_mode_still_rejects_plaintext_database
    _out, _err, result = launch('DATABASE_URL' => 'postgresql://synthetic:fixture@db.example.test/docuseal?sslmode=disable')
    assert_equal 78, result.exitstatus
  end
end
