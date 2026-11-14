# frozen_string_literal: true

# Fit JUD's printed client names without moving their reviewed field rectangle.
module BennettRetainerNameFit
  module_function

  def applies?(submission, field)
    field['type'] == 'text' && field['name'] == 'FullName' && field['readonly'] == true &&
      field['submitter_uuid'] == submission.template_submitters&.first&.fetch('uuid', nil) &&
      BennettJudEmailContext.for_submission(submission).present?
  end

  def fit(value, params, layouter, width, height)
    size = params.fetch(:font_size).to_f
    loop do
      adjusted = params.merge(font_size: size, line_height: size)
      text = HexaPDF::Layout::TextFragment.create(value, **adjusted)
      result = layouter.fit([text], width, height + 1)
      return text if result.status == :success && result.lines.sum(&:height) <= height + 1

      raise ArgumentError, 'Printed client names do not fit their retainer field' if size <= 4

      size = [size - 0.25, 4].max
    end
  end
end
