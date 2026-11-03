# frozen_string_literal: true

# Every Bennett Ruby test: ruby bennett/test/run.rb
Dir[File.join(__dir__, 'test_*.rb')].each { |file| require file }
