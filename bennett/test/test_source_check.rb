# frozen_string_literal: true

require_relative 'helper'

# The recipient-order patch and the attribution must survive every merge.
class SourceCheckTest < Minitest::Test
  def setup
    @root = BennettTest.source_copy
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def refused(pattern = nil)
    error = assert_raises(BennettSourceCheck::Failure) { BennettSourceCheck.verify!(@root) }
    assert_match(pattern, error.message) if pattern
  end

  def test_this_checkout_passes
    assert BennettSourceCheck.verify!(@root)
  end

  def test_staff_identity_checks_survive_upstream_merges
    BennettSourceCheck::STAFF_AUTH.each do |file, needles|
      needles.each do |needle|
        original = File.read(File.join(@root, file))
        BennettTest.edit(@root, file) { |text| text.gsub(needle, 'removed staff guard') }
        refused(/staff authentication missing/)
        File.write(File.join(@root, file), original)
      end
    end
  end

  def test_each_mutation_without_recipient_order_is_refused
    BennettSourceCheck::ORDERED.each_key do |file|
      original = File.read(File.join(@root, file))
      BennettTest.edit(@root, file) { |text| text.gsub(/,\s*with_order: true/, '') }
      # Plain Minitest does not load ActiveSupport's assertion aliases.
      refute_equal original, File.read(File.join(@root, file)), file
      refused(/with_order|recipient-order/)
      File.write(File.join(@root, file), original)
    end
    assert BennettSourceCheck.verify!(@root)
  end

  def test_with_order_false_is_not_enough
    BennettTest.edit(@root, 'app/controllers/submit_form_decline_controller.rb') do |text|
      text.sub('with_order: true', 'with_order: false')
    end
    refused(/with_order/)
  end

  def test_a_new_unordered_authorization_in_a_signer_controller_is_refused
    BennettTest.edit(@root, 'app/controllers/submit_form_upload_controller.rb') do |text|
      call = 'Submitters::AuthorizedForForm.call(@submitter, current_user, request)'
      text.sub(/\nend\s*\z/, "\n\n  def synthetic_new_route\n    #{call}\n  end\nend\n")
    end
    refused(/synthetic_new_route/)
  end

  def test_read_only_completed_page_may_stay_unordered
    text = File.read(File.join(@root, 'app/controllers/submit_form_controller.rb'))
    assert_match(/def completed.*?AuthorizedForForm\.call\(@submitter, current_user, request\)/m, text)
    assert BennettSourceCheck.verify!(@root)
  end

  def test_upload_routes_must_refuse_viewers
    BennettSourceCheck::VIEWER_GUARDS.each_key do |file|
      original = File.read(File.join(@root, file))
      BennettTest.edit(@root, file) { |text| text.sub("!submitter.viewer? &&\n      ", '') }
      refused(/viewers/)
      File.write(File.join(@root, file), original)
    end
  end

  def test_prefill_route_must_read_the_verification_cookie
    BennettTest.edit(@root, 'app/controllers/submit_form_prefill_attachments_controller.rb') do |text|
      text.sub("  include ActionController::Cookies\n", '')
    end
    refused(/cookie/)
  end

  def test_docuseal_attribution_must_stay
    BennettSourceCheck::ATTRIBUTION.each do |file, needles|
      original = File.read(File.join(@root, file))
      BennettTest.edit(@root, file) { |text| text.sub(needles.first, 'removed') }
      refused(/attribution/)
      File.write(File.join(@root, file), original)
    end
  end

  def test_licences_must_stay
    BennettSourceCheck::LICENSES.each do |file|
      original = File.read(File.join(@root, file))
      File.write(File.join(@root, file), "\n")
      refused(/#{file}/)
      File.unlink(File.join(@root, file))
      refused(/#{file}/)
      File.write(File.join(@root, file), original)
    end
  end

  def test_missing_linked_or_unparseable_source_is_refused
    file = 'app/controllers/submit_form_invite_controller.rb'
    target = File.join(@root, file)
    original = File.read(target)
    File.unlink(target)
    refused(/missing/)
    File.symlink(BennettTest.path(file), target)
    refused(/linked/)
    File.unlink(target)
    File.write(target, original.sub('def create', 'def create('))
    refused(/parse/)
  end
end
