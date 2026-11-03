# frozen_string_literal: true

require 'erb'
require 'pathname'
require 'yaml'
require_relative 'helper'

module Rails
  def self.root = Pathname.new('/app')
end

# bennett/storage.yml replaces config/storage.yml in the image.
class StorageTest < Minitest::Test
  BENNETT = BennettTest.read('bennett/storage.yml')
  HEADER = "# Bennett Legal override of upstream config/storage.yml: private cache metadata.\n"
  # The only intended differences from upstream.
  CHANGES = {
    "    cache_control: 'public, max-age=31536000'\n" => "    cache_control: 'private, no-store'\n",
    "  cache_control: \"public, max-age=31536000\"\n" => "  cache_control: \"private, no-store\"\n"
  }.freeze

  def test_native_s3_previews_never_get_public_cache_metadata
    config = YAML.safe_load(ERB.new(BENNETT).result)
    assert_equal 'private, no-store', config.fetch('aws_s3').fetch('upload').fetch('cache_control')
    assert_equal false, config.fetch('aws_s3').fetch('public'), 'working objects must stay private by default'
    assert_equal 'private, no-store', config.fetch('google').fetch('cache_control')
    refute_match(/public, max-age/, BENNETT)
  end

  # If upstream changes config/storage.yml, the override would silently drop
  # that change. Fail instead, so a person carries it into bennett/storage.yml.
  def test_override_is_upstream_plus_only_the_cache_policy
    expected = CHANGES.reduce(BennettTest.read('config/storage.yml')) do |text, (from, to)|
      assert_equal 1, text.scan(from).length, "upstream config/storage.yml changed near: #{from.strip}"
      text.sub(from, to)
    end
    assert_equal HEADER + expected, BENNETT,
                 'config/storage.yml changed upstream: carry the change into bennett/storage.yml'
  end
end
