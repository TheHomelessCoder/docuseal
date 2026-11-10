# frozen_string_literal: true

require_relative 'helper'
require_relative '../../app/helpers/bennett_staff_helper'

class StaffDocumentLanguageTest < Minitest::Test
  Record = Struct.new(:name, :schema, :template_schema)

  def setup
    @helper = Object.new.extend(BennettStaffHelper)
  end

  def test_frozen_submission_document_wins_over_a_renamed_template
    template = Record.new('Contrato de Empleo y Acuerdo de Honorarios', [{ 'name' => 'retainer-es-original' }])
    submission = Record.new(nil, nil, [{ 'name' => 'retainer-en-original' }])
    assert_equal 'es', @helper.bennett_staff_document_language(template:)
    assert_equal 'en', @helper.bennett_staff_document_language(template:, submission:)
  end

  def test_old_spanish_import_and_practice_clone_heading
    title = 'Contrato de Empleo y Acuerdo de Honorarios'
    [title, "PRACTICE — NOT A CONTRACT — #{title}"].each do |name|
      assert_equal 'es', @helper.bennett_staff_document_language(template: Record.new(name, []))
    end
  end

  def test_unknown_and_mixed_documents_are_not_guessed_from_staff_or_client_language
    assert_nil @helper.bennett_staff_document_language(template: Record.new('Guide for Spanish clients', []))
    mixed = [{ 'name' => 'retainer-en-original' }, { 'name' => 'retainer-es-original' }]
    assert_nil @helper.bennett_staff_document_language(template: Record.new('Mixed packet', mixed))
    assert_nil @helper.bennett_staff_document_language(template: nil)
  end

  def test_practice_heading_can_be_shortened_without_losing_its_classification
    title = 'PRACTICE — NOT A CONTRACT — Employment Contract and Fee Agreement'
    assert @helper.bennett_staff_practice_document?(title)
    assert_equal 'Employment Contract and Fee Agreement', @helper.bennett_staff_document_title(title)
    assert_equal false, @helper.bennett_staff_practice_document?('Employment Contract and Fee Agreement')
  end
end
