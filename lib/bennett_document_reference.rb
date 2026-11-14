# frozen_string_literal: true

require 'digest'

# Bennett Legal, 2026-11-10: identify JUD agreements in the same upper-left
# margin used by their former envelope header, using DocuSeal's native ID.
module BennettDocumentReference
  MARKER = :BennettDocumentIDHeaderV1
  FONT_SIZE = 8
  LEFT = 17
  TOP = 17

  module_function

  def enabled_for?(submission)
    BennettJudEmailContext.for_submission(submission).present? &&
      AccountConfig.exists?(account_id: submission.account_id, key: AccountConfig::WITH_SIGNATURE_ID, value: true)
  end

  def preview_attachments(submitter)
    submitter.with_lock do
      submitter.preview_documents.reset
      submission = submitter.submission
      values_hash = "#{Submissions::GeneratePreviewAttachments.build_submitter_values_hash(submitter)}:#{MARKER}"
      cached = submitter.preview_documents.to_a
      documents = submission.schema_documents.preload(:blob).to_a
      schema = Submissions.filtered_conditions_schema(submission)
      expected = schema.filter_map do |item|
        item['attachment_uuid'] if documents.any? { |document| document.uuid == item['attachment_uuid'] }
      end
      images = documents.select(&:image?)
      if images.many? { |image| expected.include?(image.uuid) }
        expected << Submissions::GenerateResultAttachments.images_pdf_uuid(images)
      end

      if cached.map { |attachment| attachment.metadata['original_uuid'] }.tally == expected.tally &&
         cached.all? { |attachment| attachment.metadata['values_hash'] == values_hash }
        next cached
      end

      ApplicationRecord.no_touching { cached.each(&:destroy) }
      Submissions::GeneratePreviewAttachments.call(submission, submitter:, values_hash:)
    end
  end

  def add_headers(pdfs, submission)
    return unless BennettJudEmailContext.for_submission(submission)

    document_id = Digest::MD5.hexdigest(submission.slug).upcase
    pdfs.each_value do |pdf|
      existing = pdf.trailer.info[:DocumentID]
      marker = pdf.trailer.info[MARKER]
      if (existing.present? && existing != document_id) || (marker.present? && marker != document_id)
        raise 'JUD document reference does not match its submission'
      end
      next if marker == document_id

      font = pdf.fonts.add(Submissions::GenerateResultAttachments::FONT_NAME)
      pdf.pages.each do |page|
        canvas = page.canvas(type: :overlay)
        canvas.save_graphics_state do
          canvas.fill_color('white').rectangle(page.box.left + 16, page.box.top - 22, 280, 15).fill
          canvas.fill_color('444444').font(font, size: FONT_SIZE)
                .text("DocuSeal Document ID: #{document_id}", at: [page.box.left + LEFT, page.box.top - TOP])
        end
      end
      pdf.trailer.info[MARKER] = document_id
    end
  end
end
