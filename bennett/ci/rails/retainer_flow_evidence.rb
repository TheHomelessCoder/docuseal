# frozen_string_literal: true

# Inspect actual artifacts produced by the browser flows, not regenerated copies.
require 'json'

raise 'Synthetic CI stack required' unless ENV['APP_URL'] == 'https://sign.ci.test' &&
                                           Account.first&.name == 'Bennett Legal (smoke test)'

class BennettFlowText < HexaPDF::Content::Processor
  attr_reader :lines

  def initialize
    super
    @lines = []
  end

  def show_text(data)
    @lines << decode_text_with_positioning(data).string
  end
  alias show_text_with_positioning show_text
end

checks = 0
check = lambda do |condition, label|
  raise "Private-link evidence: #{label}" unless condition

  checks += 1
end
flows = JSON.parse(ENV.fetch('CI_RETAINER_FLOW_EVIDENCE'))
check.call(flows.size == 4, 'four completed flows')
references = []
root_pem = Account.first!.encrypted_configs.find_by!(key: EncryptedConfig::ESIGN_CERTS_KEY).value.fetch('root_ca')
trusted_root = OpenSSL::X509::Certificate.new(root_pem)
flows.each do |flow|
  submission = Submission.find(flow.fetch('submission_id'))
  check.call(submission.variables['bennett_issuance_id'] == flow.fetch('issuance_id'), 'issuance binding')
  check.call(BennettDocumentReference.enabled_for?(submission), 'validated JUD context and account selection')
  reference = Digest::MD5.hexdigest(submission.slug).upcase
  references << reference
  signers = submission.submitters.to_a
  client, attorney = submission.template_submitters.map { |role| signers.find { |s| s.uuid == role['uuid'] } }
  check.call(client.completed_at && attorney.completed_at && client.completed_at <= attorney.completed_at, 'signer timestamp order')
  check.call(signers.all? { |s| s.preferences['require_email_2fa'] == false }, 'private-link access persisted')
  check.call(client.preview_documents.size == 1, 'repeated unsigned downloads share one cached preview')

  unsigned = client.preview_documents.first.download
  signed = attorney.documents.first.download
  audit = submission.audit_trail.download
  { unsigned: [unsigned, flow.fetch('unsigned_sha256')], signed: [signed, flow.fetch('signed_sha256')],
    audit: [audit, flow.fetch('audit_sha256')] }.each do |kind, (bytes, expected_hash)|
    check.call(Digest::SHA256.hexdigest(bytes) == expected_hash, "actual browser #{kind} bytes match stored evidence")
    document = HexaPDF::Document.new(io: StringIO.new(bytes))
    all_text = []
    document.pages.each do |page|
      reader = BennettFlowText.new
      page.process_contents(reader)
      all_text.concat(reader.lines)
      next if kind == :audit

      headers = reader.lines.select { |line| line.start_with?('DocuSeal Document ID:') }
      check.call(headers == ["DocuSeal Document ID: #{reference}"], "#{kind} has exactly one matching header on every page")
      check.call(reader.lines.any? { |line| line.include?('SYNTHETIC CI RETAINER') }, "#{kind} retains source body")
    end
    if kind == :audit
      check.call(all_text.join(' ').include?(reference), 'audit uses the same native document reference')
    else
      check.call(document.pages.count == 2, "#{kind} retains all pages")
      check.call(document.trailer.info[BennettDocumentReference::MARKER] == reference, "#{kind} persisted header marker")
      check.call(document.trailer.info[:DocumentID] == reference, 'signed native PDF reference') if kind == :signed
      if kind == :signed
        signatures = document.signatures.to_a
        check.call(signatures.size == 1, 'final document has one native digital seal')
        signatures.each do |signature|
          pkcs = OpenSSL::PKCS7.new(signature.contents)
          check.call(pkcs.certificates.all? { |cert| cert.serial.to_i.positive? && cert.serial.num_bits <= 159 },
                     'all certificate serials fit the positive 20-octet DER limit')
          check.call(signature.verify(default_paths: false, trusted_certs: [trusted_root]).success?,
                     'cryptographic signature and pinned CI certificate chain verify')
          check.call(signature[:ByteRange].to_a.last(2).sum == bytes.bytesize, 'digital seal covers the full result')
        end
      end
      check.call(all_text.join(' ').include?(flow.fetch('client_name')), "#{kind} retains the client name")
      check.call(all_text.join(' ').include?('3,000'), "#{kind} retains the fee")
    end
  end
end
check.call(references.uniq.size == flows.size, 'separate agreements have separate native references')
puts({ retainer_flow_evidence: 'passed', flows: flows.size, checks:, delivered: 'Mailpit only' }.to_json)
