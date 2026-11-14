# frozen_string_literal: true

# Real preview/result renderers in the disposable smoke database. No delivery.
require 'json'

ActionMailer::Base.perform_deliveries = false
ActiveJob::Base.queue_adapter = :test

class BennettReferenceText < HexaPDF::Content::Processor
  attr_reader :items

  def initialize
    super
    @items = []
  end

  def show_text(data)
    origin = graphics_state.ctm.dup.premultiply(*graphics_state.tm).evaluate(0, graphics_state.text_rise)
    size = graphics_state.font_size
    text = decode_text_with_positioning(data)
    @items << [text.string, origin, size] unless text.boxes.empty?
  end
  alias show_text_with_positioning show_text
end

class BennettReferenceFixture
  attr_reader :checks

  def initialize
    @checks = 0
    @account = Account.create!(name: 'Synthetic document reference', locale: 'en', timezone: 'UTC')
    @user = @account.users.create!(email: 'reference@example.invalid', first_name: 'Synthetic', last_name: 'Reference',
                                   password: SecureRandom.hex(20))
    @config = @account.account_configs.create!(key: AccountConfig::WITH_SIGNATURE_ID, value: true)
  end

  def check(condition, message)
    raise "Document reference: #{message}" unless condition

    @checks += 1
  end

  def build(language, tagged: true, client_name: nil)
    pdf = HexaPDF::Document.new
    2.times do |index|
      canvas = pdf.pages.add([0, 0, 612, 792]).canvas
      canvas.font('Helvetica', size: 12).text("Synthetic unchanged agreement body #{index + 1}", at: [72, 700])
    end
    file = Tempfile.new(['reference-fixture', '.pdf'], binmode: true)
    pdf.write(file)
    file.rewind
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: 'synthetic-reference.pdf',
                                                    type: 'application/pdf')
    roles = [{ 'name' => 'Client', 'uuid' => SecureRandom.uuid }, { 'name' => 'Attorney', 'uuid' => SecureRandom.uuid }]
    template = Template.create!(account: @account, author: @user, name: 'Synthetic reference', fields: [],
                                submitters: roles, preferences: { 'submitters_order' => 'preserved' })
    documents, = Templates::CreateAttachments.call(template, { files: [upload] })
    template.update!(schema: documents.map { |doc| { attachment_uuid: doc.uuid, name: 'Synthetic reference' } })
    if client_name
      attachment = documents.first.uuid
      template.update!(fields: [{ 'uuid' => SecureRandom.uuid, 'name' => 'FullName', 'type' => 'text',
                                  'readonly' => true, 'required' => true, 'submitter_uuid' => roles.first['uuid'],
                                  'preferences' => { 'font_size' => 9, 'valign' => 'center' },
                                  'areas' => [{ 'attachment_uuid' => attachment, 'page' => 1,
                                                'x' => 211.0 / 612, 'y' => 328.0 / 792,
                                                'w' => 300.0 / 612, 'h' => 16.0 / 792 }] }])
    end
    issuance = SecureRandom.uuid
    submission = Submission.create!(account: @account, template:, created_by_user: @user,
                                    submitters_order: 'preserved', template_fields: template.fields,
                                    template_submitters: roles,
                                    template_schema: JSON.parse(template.schema.to_json),
                                    variables: tagged ? { 'bennett_issuance_id' => issuance } : {})
    roles.each_with_index do |role, index|
      metadata = { 'lang' => language }
      if index == 1
        metadata['bennett_jud_context'] = { 'version' => 'jud-retainer-email/1', 'issuance_id' => issuance,
                                            'record_type' => 'case', 'reference' => 'SOLAR-2099-00001',
                                            'url' => 'https://jud.bennettlegal.com/solar/cases/1',
                                            'client_name' => 'Synthetic Client' }
      end
      values = index.zero? && client_name ? { template.fields.first.fetch('uuid') => client_name } : {}
      submission.submitters.create!(account: @account, uuid: role['uuid'], name: "Synthetic #{role['name']}",
                                    email: "#{index}@example.invalid", external_id: "#{issuance}:#{index}", metadata:,
                                    values:)
    end
    submission
  ensure
    file&.close!
  end

  def inspect_pdf(pdf, submission, expected: true)
    reference = Digest::MD5.hexdigest(submission.slug).upcase
    pdf.pages.each_with_index do |page, index|
      reader = BennettReferenceText.new
      page.process_contents(reader)
      headers = reader.items.select { |item| item[0].start_with?('DocuSeal Document ID:') }
      check(headers.size == (expected ? 1 : 0), 'one header per page only when selected')
      check(reader.items.any? { |item| item[0] == "Synthetic unchanged agreement body #{index + 1}" }, 'body retained')
      next unless expected

      text, origin, size = headers.first
      check(text == "DocuSeal Document ID: #{reference}", 'native submission reference')
      # The Unicode font's global bounding box includes glyphs absent from this
      # ASCII header. Check its actual text origin/size, then review the PDF ink.
      check((origin[0] - 17).abs < 0.01 && (origin[1] - (page.box.top - 17)).abs < 0.01 && size == 8,
            'upper-left reserved margin')
    end
    reference
  end

  def run
    long_names = 'María Guadalupe Fernández Hernández & José Alejandro González Rodríguez'
    %w[en es].each do |language|
      shared = build(language, client_name: long_names)
      preview = Submissions::GeneratePreviewAttachments.call(shared).first
      result = Submissions::GenerateResultAttachments.generate_pdfs(shared.submitters.first).values.first
      [HexaPDF::Document.new(io: StringIO.new(preview.download)), result].each do |pdf|
        reader = BennettReferenceText.new
        pdf.pages[1].process_contents(reader)
        name = reader.items.find { |item| item[0] == long_names }
        check(name && name[2] < 9 && name[2] >= 4, 'complete shared names fit the fixed field in preview and result')
      end
    end
    cached_submission = build('en')
    signer = cached_submission.submitters.first
    first = BennettDocumentReference.preview_attachments(signer).first
    source_uuid = first.metadata.fetch('original_uuid')
    original_blob = first.blob_id
    duplicate_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(first.download), filename: 'duplicate.pdf')
    ActiveStorage::Attachment.create!(record: signer, name: 'preview_documents', blob: duplicate_blob,
                                      metadata: first.metadata.deep_dup)
    check(signer.preview_documents.reload.size == 2, 'duplicate-cache negative control is present')
    repaired = BennettDocumentReference.preview_attachments(signer)
    check(repaired.size == 1 && signer.preview_documents.reload.size == 1,
          'duplicate cache is replaced with one source preview')
    check(repaired.first.metadata['original_uuid'] == source_uuid && repaired.first.blob_id != original_blob,
          'duplicate repair regenerates the expected source')
    repaired.first.update!(metadata: repaired.first.metadata.merge('original_uuid' => 'foreign-source'))
    corrected = BennettDocumentReference.preview_attachments(signer)
    check(corrected.size == 1 && corrected.first.metadata['original_uuid'] == source_uuid,
          'same-size foreign cache is replaced')
    inspect_pdf(HexaPDF::Document.new(io: StringIO.new(corrected.first.download)), cached_submission)

    references = %w[en es].map do |language|
      submission = build(language)
      preview = Submissions::GeneratePreviewAttachments.call(submission).first
      File.binwrite("/tmp/bennett-reference-#{language}-preview.pdf", preview.download)
      inspect_pdf(HexaPDF::Document.new(io: StringIO.new(preview.download)), submission)
      pdfs = Submissions::GenerateResultAttachments.generate_pdfs(submission.submitters.first)
      pdfs.values.first.write("/tmp/bennett-reference-#{language}-result.pdf")
      reference = inspect_pdf(pdfs.values.first, submission)
      check(pdfs.values.first.trailer.info[:DocumentID] == reference, 'native PDF metadata and header agree')
      BennettDocumentReference.add_headers(pdfs, submission)
      inspect_pdf(pdfs.values.first, submission)
      io = StringIO.new
      pdfs.values.first.write(io)
      reopened = HexaPDF::Document.new(io: StringIO.new(io.string))
      BennettDocumentReference.add_headers({ 'reopened' => reopened }, submission)
      inspect_pdf(reopened, submission)
      reference
    end
    check(references.uniq.size == 2, 'different agreements have different references')
    untagged = build('en', tagged: false)
    preview = Submissions::GeneratePreviewAttachments.call(untagged).first
    inspect_pdf(HexaPDF::Document.new(io: StringIO.new(preview.download)), untagged, expected: false)
    @config.update!(value: false)
    disabled = build('es')
    preview = Submissions::GeneratePreviewAttachments.call(disabled).first
    inspect_pdf(HexaPDF::Document.new(io: StringIO.new(preview.download)), disabled, expected: false)
    inspect_pdf(Submissions::GenerateResultAttachments.generate_pdfs(disabled.submitters.first).values.first,
                disabled, expected: false)
  end
end

ActiveRecord::Base.transaction do
  fixture = BennettReferenceFixture.new
  fixture.run
  puts({ document_reference: 'passed', checks: fixture.checks, delivered: false }.to_json)
  raise ActiveRecord::Rollback
end
