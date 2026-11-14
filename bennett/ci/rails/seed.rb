# frozen_string_literal: true

# Synthetic smoke-test data, shaped like the approved retainers: a Client then
# Attorney template with recipient order preserved, an empty draft for the
# import PUT, and the JUD webhook. Generated PDF and example.test identities
# only. Prints one JSON line: ids and hashes, no secrets.
#
#   docker exec -i -w /app -e CI_WEBHOOK_URL -e CI_WEBHOOK_SECRET <docuseal> bin/rails runner - < seed.rb
require 'json'

account = Account.first!
user = account.users.first!
account.account_configs.find_or_initialize_by(key: AccountConfig::WITH_SIGNATURE_ID).update!(value: true)

pdf = HexaPDF::Document.new
2.times do |index|
  canvas = pdf.pages.add.canvas
  canvas.font('Helvetica', size: 18).text("SYNTHETIC CI RETAINER - NOT A CONTRACT (page #{index + 1} of 2)",
                                          at: [72, 720])
  canvas.font('Helvetica', size: 11).text('Nightly build check for the Bennett Legal signing service.', at: [72, 690])
end
io = StringIO.new
pdf.write(io)
bytes = io.string

upload = lambda do |name|
  file = Tempfile.new([name, '.pdf'], binmode: true)
  file.write(bytes)
  file.rewind
  ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "#{name}.pdf", type: 'application/pdf')
end
roles = lambda {
  [{ 'name' => 'Client', 'uuid' => SecureRandom.uuid }, { 'name' => 'Attorney', 'uuid' => SecureRandom.uuid }]
}
create = lambda do |name, external_id|
  template = Template.create!(account:, author: user, name:, external_id:, submitters: roles.call,
                              preferences: { 'submitters_order' => 'preserved' })
  documents, = Templates::CreateAttachments.call(template, { files: [upload.call(external_id)] })
  template.update!(schema: documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } })
  [template, documents.first]
end

template, document = create.call('CI retainer (synthetic)', 'ci-retainer')
client, attorney = template.submitters.pluck('uuid')
area = lambda { |page, x, y, w = 0.3, h = 0.04|
  { 'attachment_uuid' => document.uuid, 'page' => page, 'x' => x, 'y' => y, 'w' => w, 'h' => h }
}
field = lambda do |role, name, type, place|
  { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => role, 'name' => name, 'type' => type, 'required' => true,
    'preferences' => {}, 'areas' => [place] }
end
template.update!(fields: [
                   field.call(client, 'FullName', 'text', area.call(0, 0.1, 0.2)),
                   field.call(client, 'attorney_fee', 'text', area.call(0, 0.1, 0.3)),
                   field.call(client, 'Consent', 'checkbox', area.call(1, 0.1, 0.2, 0.03, 0.03)),
                   field.call(client, 'Signature', 'signature', area.call(1, 0.1, 0.3, 0.35, 0.08)),
                   field.call(client, 'DateSigned', 'date', area.call(1, 0.55, 0.33)),
                   field.call(attorney, 'AttorneySignature', 'signature', area.call(1, 0.1, 0.6, 0.35, 0.08)),
                   field.call(attorney, 'AttorneyDate', 'date', area.call(1, 0.55, 0.63))
                 ])

draft, draft_document = create.call('CI import draft (synthetic)', 'ci-import-draft')

webhook = account.webhook_urls.create!(url: ENV.fetch('CI_WEBHOOK_URL'), hmac_secret: ENV.fetch('CI_WEBHOOK_SECRET'),
                                       events: %w[form.completed form.declined submission.completed submission.expired])

puts({ template_id: template.id, draft_id: draft.id, document_sha256: Digest::SHA256.hexdigest(bytes), pages: 2,
       draft_document_uuid: draft_document.uuid, preview_images: document.preview_images.count,
       webhook: webhook.persisted? }.to_json)
