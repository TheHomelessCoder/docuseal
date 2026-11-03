# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../source_check'

# Plain Ruby; no Rails, database, network or credentials.
module BennettTest
  ROOT = File.expand_path('../..', __dir__)
  CHECKED = (BennettSourceCheck::ORDERED.keys | BennettSourceCheck::VIEWER_GUARDS.keys | BennettSourceCheck::COOKIES |
             BennettSourceCheck::ATTRIBUTION.keys | BennettSourceCheck::LICENSES).freeze

  module_function

  def path(*parts) = File.join(ROOT, *parts)

  def read(*parts) = File.read(path(*parts))

  # A throwaway copy of every file the source check reads.
  def source_copy
    root = Dir.mktmpdir('bennett-source-')
    CHECKED.each do |file|
      FileUtils.mkdir_p(File.dirname(File.join(root, file)))
      FileUtils.cp(path(file), File.join(root, file))
    end
    root
  end

  def edit(root, file)
    target = File.join(root, file)
    File.write(target, yield(File.read(target)))
  end
end
