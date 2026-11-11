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
