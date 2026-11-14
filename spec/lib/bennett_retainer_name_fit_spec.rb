# frozen_string_literal: true

require 'hexapdf'
require_relative '../../lib/bennett_retainer_name_fit'

RSpec.describe BennettRetainerNameFit do
  let(:font) { HexaPDF::Document.new.fonts.add('Helvetica') }
  let(:params) { { font:, font_size: 9, line_height: 9 } }
  let(:layouter) { HexaPDF::Layout::TextLayouter.new(font:, font_size: 9) }

  let(:long_name) do
    word = 'W' * 35
    "#{word} #{word} & #{word} #{word}"
  end

  it 'retains the original size for a single name or ordinary pair' do
    ['María José Núñez', 'María García & Juan Pérez'].each do |name|
      text = described_class.fit(name, params, layouter, 300, 16)
      expect(text.style.font_size).to eq(9)
      expect(text.text).to eq(name)
    end
  end

  [300, 325].each do |width|
    it "fits long names inside the #{width}-point field without changing their text" do
      name = long_name
      base = HexaPDF::Layout::TextFragment.create(name, **params)
      expect(layouter.fit([base], width, 17).status).not_to eq(:success)
      text = described_class.fit(name, params, layouter, width, 16)
      result = layouter.fit([text], width, 17)
      expect(result.status).to eq(:success)
      expect(result.lines.sum(&:height)).to be <= 17
      expect(text.style.font_size).to be < 9
      expect(text.style.font_size).to be >= 4
      expect(text.text).to eq(name)
    end
  end

  it 'refuses overflow beyond the minimum size instead of losing text' do
    expect { described_class.fit('W' * 200, params, layouter, 10, 10) }
      .to raise_error(ArgumentError, 'Printed client names do not fit their retainer field')
  end

  it 'selects only the readonly client FullName field of a validated JUD submission' do
    stub_const('BennettJudEmailContext', Class.new { def self.for_submission(*); end })
    submission = Struct.new(:template_submitters).new([{ 'uuid' => 'client' }, { 'uuid' => 'firm' }])
    field = { 'name' => 'FullName', 'type' => 'text', 'readonly' => true, 'submitter_uuid' => 'client' }
    allow(BennettJudEmailContext).to receive(:for_submission).with(submission).and_return({ reference: 'SYNTHETIC' })
    expect(described_class).to be_applies(submission, field)
    expect(described_class).not_to be_applies(submission, field.merge('submitter_uuid' => 'firm'))
    expect(described_class).not_to be_applies(submission, field.merge('readonly' => false))
    expect(described_class).not_to be_applies(submission, field.merge('name' => 'Other'))
    allow(BennettJudEmailContext).to receive(:for_submission).with(submission).and_return(nil)
    expect(described_class).not_to be_applies(submission, field)
  end
end
