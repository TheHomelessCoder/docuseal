# frozen_string_literal: true

# Verify actual serialized mail with synthetic records in a rollback transaction.
# Nothing is delivered. Run only in the disposable smoke-test database.
# Optionally write private synthetic previews to RENDER_OUT.
require 'json'

OUT = ENV.fetch('RENDER_OUT', nil)

ActiveRecord::Base.transaction do
  # The copy and completed emails would otherwise build the signed documents.
  SubmitterMailer.prepend(Module.new do
    private

    def add_completed_email_attachments!(*)
      attachments['synthetic-document.pdf'] =
        { mime_type: 'application/pdf', content: '%PDF-1.4 synthetic test attachment' }
    end
  end)

  account = Account.create!(name: 'Bennett Legal', locale: 'en-US', timezone: 'America/Chicago')
  user = account.users.create!(email: 'stephen@notify.bennettlegal.com', first_name: 'Stephen',
                               last_name: 'Phillips', password: SecureRandom.hex(16))
  fields = [{ 'uuid' => SecureRandom.uuid, 'submitter_uuid' => 'client-role', 'name' => 'Signature',
              'type' => 'signature', 'required' => true, 'areas' => [] }]
  template = Template.create!(account:, author: user, name: 'Retainer Agreement', fields:,
                              submitters: [{ 'name' => 'Client', 'uuid' => 'client-role' }], source: 'api')

  signer = lambda do |name:, lang:, source: 'api', from: template|
    submission = Submission.create!(account:, template: from, created_by_user: user, source:,
                                    submitters_order: 'preserved',
                                    template_fields: from.fields, template_submitters: from.submitters,
                                    template_schema: from.schema, name: from.name)
    Submitter.create!(account:, submission:, uuid: 'client-role', name:, email: 'maria.garcia@example.invalid',
                      metadata: { 'lang' => lang }, preferences: { 'require_email_2fa' => true })
  end

  results = []
  render = lambda do |name, delivery|
    message = delivery.message
    HtmlToPlainTextInterceptor.process(message)
    # Encode and parse again: assert what the mail client receives, including the
    # multipart structure after the plain-text interceptor and PDF attachments.
    message = Mail.read_from_string(message.to_s)
    html = message.html_part.body.decoded.force_encoding('UTF-8')
    text = message.text_part.body.decoded.force_encoding('UTF-8')
    expected = %w[footer-logo linkedin-gold instagram-gold facebook-gold youtube-gold].map do |asset|
      "bennett-mail-#{asset}.png"
    end
    inlines = message.attachments.select(&:inline?)
    raise "#{name}: missing or duplicate inline artwork" unless inlines.map(&:filename).sort == expected.sort

    inlines.each do |part|
      raise "#{name}: wrong MIME type" unless part.mime_type == 'image/png'

      artwork = Rails.public_path.join('packs', part.filename).binread
      raise "#{name}: changed artwork" unless part.body.decoded == artwork
    end
    images = Nokogiri::HTML.fragment(html).css('img')
    raise "#{name}: missing header/footer images" unless images.length == 6

    images.each do |image|
      source = image['src']
      raise "#{name}: remote artwork dependency" unless source.start_with?('cid:')

      matches = inlines.select { |part| part.cid == CGI.unescape(source.delete_prefix('cid:')) }
      raise "#{name}: unresolved image" unless matches.length == 1

      image['src'] = "data:image/png;base64,#{Base64.strict_encode64(matches.first.body.decoded)}"
    end
    if name.start_with?('copy-') || name == 'completed-staff'
      document = message.attachments['synthetic-document.pdf']&.body&.decoded
      raise "#{name}: document lost" unless document == '%PDF-1.4 synthetic test attachment'
    end
    raise "#{name}: no plain text" if text.strip.empty?
    raise "#{name}: MIME/CSS leaked into text" if text.match?(/cid:|<style|email-paper\{/)

    if OUT
      # A local visual preview resolves only bytes actually present in the MIME.
      resolved = Nokogiri::HTML.fragment(html)
      resolved.css('img').each_with_index { |image, i| image['src'] = images[i]['src'] }
      File.write(File.join(OUT, "#{name}.html"), resolved.to_html)
      File.write(File.join(OUT, "#{name}.eml"), message.to_s)
    end
    results << { name:, inline_images: inlines.length, images_resolved: images.length, ok: true }
  rescue StandardError => e
    results << { name:, error: "#{e.class}: #{e.message}", at: e.backtrace.first(4) }
  end

  en = signer.call(name: 'Maria Garcia', lang: 'en')
  es = signer.call(name: 'María García', lang: 'es')
  render.call('invitation-en', SubmitterMailer.invitation_email(en))
  render.call('invitation-es', SubmitterMailer.invitation_email(es))
  render.call('code-en', SubmitterMailer.otp_verification_email(en))
  render.call('code-es', SubmitterMailer.otp_verification_email(es))
  render.call('copy-en', SubmitterMailer.documents_copy_email(en, sig: true))
  render.call('copy-es', SubmitterMailer.documents_copy_email(es, sig: true))
  render.call('view-invitation-en', SubmitterMailer.invitation_view_email(en))

  # A custom body (account or template setting) with the signing link appended.
  custom = Template.create!(account:, author: user, name: 'Retainer Agreement', fields:, source: 'api',
                            submitters: [{ 'name' => 'Client', 'uuid' => 'client-role' }],
                            preferences: { 'request_email_body' => "Hello {submitter.name},\n\n" \
                                                                   "Please review and sign your agreement.\n\n" \
                                                                   "Thank you,\nBennett Legal" })
  custom_signer = signer.call(name: 'Maria Garcia', lang: 'en', source: 'invite', from: custom)
  render.call('invitation-custom-body-en', SubmitterMailer.invitation_email(custom_signer))

  # Staff and account mail.
  en.update!(completed_at: Time.current)
  render.call('completed-staff', SubmitterMailer.completed_email(en, user))
  SubmissionEvent.create!(account:, submission: es.submission, submitter: es, event_type: 'decline_form',
                          data: { 'reason' => 'I would like to speak with an attorney first.' })
  es.update!(declined_at: Time.current)
  render.call('declined-staff', SubmitterMailer.declined_email(es, user))
  render.call('user-invitation', UserMailer.invitation_email(user))
  render.call('password-reset', Devise::Mailer.reset_password_instructions(user, 'synthetic-token'))
  render.call('template-code', TemplateMailer.otp_verification_email(template, email: 'maria.garcia@example.invalid'))
  render.call('smtp-setup', SettingsMailer.smtp_successful_setup('stephen@notify.bennettlegal.com'))

  File.write(File.join(OUT, 'index.json'), "#{JSON.pretty_generate(results)}\n") if OUT
  raise "Email MIME check failed: #{results.reject { |r| r[:ok] }.to_json}" unless results.all? { |r| r[:ok] }

  puts({ mail_assets: 'passed', messages: results.length, delivered: false }.to_json)
  raise ActiveRecord::Rollback
end
