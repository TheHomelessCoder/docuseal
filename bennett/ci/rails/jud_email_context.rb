# frozen_string_literal: true

# Synthetic rollback fixture only. Exercise the real mailers without delivery.
require 'json'

ActionMailer::Base.perform_deliveries = false
ActionMailer::Base.delivery_method = :test
ActiveJob::Base.queue_adapter = :test
ENV['BENNETT_STAFF_ACCESS_ENABLED'] = 'true'
ENV['BENNETT_STAFF_ACCESS_HOST'] = 'staff.jud-mail.example.invalid'
ENV['BENNETT_STAFF_ACCESS_TEAM'] = 'jud-mail-fixture'
ENV['BENNETT_STAFF_ACCESS_AUD'] = '0' * 64

SubmitterMailer.prepend(Module.new do
  private

  def add_completed_email_attachments!(*)
    attachments['synthetic-document.pdf'] =
      { mime_type: 'application/pdf', content: '%PDF synthetic JUD email fixture' }
  end
end)

class JudEmailContextFixture
  LANGUAGES = %w[en es].freeze
  KINDS = %w[case lead].freeze

  attr_reader :checks, :messages

  def initialize
    @checks = 0
    @messages = 0
    @staff_links = 0
    @account = Account.create!(name: 'Bennett Legal JUD email fixture', locale: 'en', timezone: 'America/Chicago')
    @user = @account.users.create!(email: 'jud-staff@example.invalid', first_name: 'Synthetic', last_name: 'Staff',
                                   password: SecureRandom.hex(20))
    @account.users.create!(email: 'client@example.invalid', first_name: 'Synthetic', last_name: 'Client Account',
                           password: SecureRandom.hex(20))
  end

  def check(value, description)
    raise "JUD email context: #{description}" unless value

    @checks += 1
  end

  def build(language, kind, finished: true)
    roles = [{ 'name' => 'Client', 'uuid' => 'client-role' }, { 'name' => 'Attorney', 'uuid' => 'firm-role' }]
    fields = roles.map do |r|
      { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => r['uuid'], 'name' => 'Signature', 'type' => 'signature',
        'areas' => [] }
    end
    template = Template.create!(account: @account, author: @user, name: 'Synthetic JUD retainer', fields:,
                                submitters: roles)
    issuance = SecureRandom.uuid
    submission = Submission.create!(account: @account, template:, created_by_user: @user, source: 'api',
                                    submitters_order: 'preserved', template_fields: fields, template_submitters: roles,
                                    template_schema: [], name: template.name,
                                    variables: { 'bennett_issuance_id' => issuance })
    reference = kind == 'case' ? 'SOLAR-2099-00123' : 'LEAD-2099-00025'
    url = kind == 'case' ? 'https://jud.bennettlegal.com/solar/cases/9123' : "https://jud.bennettlegal.com/intake/leads##{reference}"
    context = { 'version' => 'jud-retainer-email/1', 'issuance_id' => issuance, 'record_type' => kind,
                'reference' => reference, 'url' => url, 'client_name' => 'Synthetic Client' }
    client = signer(submission, roles[0], "#{issuance}:0", { 'lang' => language }, finished:)
    firm = signer(submission, roles[1], "#{issuance}:1",
                  { 'lang' => language, 'bennett_jud_context' => context }, finished:)
    SubmissionEvent.create!(account: @account, submission:, submitter: client, event_type: 'decline_form',
                            data: { 'reason' => 'Synthetic decline' })
    { submission:, template:, client:, firm:, context: }
  end

  def signer(submission, role, external_id, metadata, finished:)
    email = role['name'] == 'Client' ? 'client@example.invalid' : 'attorney@example.invalid'
    Submitter.create!(account: @account, submission:, uuid: role['uuid'], name: "Synthetic #{role['name']}", email:,
                      external_id:, metadata:, preferences: { 'send_email' => finished || role['name'] == 'Client' },
                      completed_at: finished ? Time.current : nil)
  end

  def mail(delivery, record, internal:, document: false, custom: nil)
    message = delivery.message
    HtmlToPlainTextInterceptor.process(message)
    message = Mail.read_from_string(message.to_s)
    html = Nokogiri::HTML.fragment(message.html_part.body.decoded.force_encoding('UTF-8'))
    text = message.text_part.body.decoded.force_encoding('UTF-8')
    check(html.text.include?(custom), 'custom body retained') if custom
    check_context(message, html, text, record, internal:)
    check_links(html, record)
    check_artwork(message, html, text, document:)
    @messages += 1
  end

  def check_links(html, record)
    routes = Rails.application.routes.url_helpers
    staff_path = routes.submission_path(record[:submission])
    public_paths = [
      routes.submissions_preview_path(record[:submission].slug),
      routes.submit_form_path(slug: record[:firm].slug),
      routes.submit_form_path(slug: record[:client].slug)
    ]
    html.css('a').filter_map { |a| a['href'] }.each do |url|
      uri = URI.parse(url)
      if uri.path == staff_path
        check(uri.scheme == 'https' && uri.host == ENV.fetch('BENNETT_STAFF_ACCESS_HOST') && uri.port == 443,
              'administration link uses the protected staff host')
        @staff_links += 1
      elsif public_paths.include?(uri.path)
        check(uri.host == ENV.fetch('EMAIL_HOST', Docuseal.default_url_options[:host]),
              'signing and signed-document links stay on the public host')
      end
    end
  end

  def check_context(message, html, text, record, internal:)
    links = html.css('a').filter_map { |a| a['href'] }
    if internal
      check(links.count(record[:context]['url']) == 1, 'one exact JUD anchor')
      check(text.include?(record[:context]['url']), 'plain-text JUD URL')
      check(message.subject.include?(record[:context]['reference']), 'subject reference')
      check(html.text.include?(record[:context]['client_name']), 'literal client name')
    else
      check(links.none? do |url|
        url.start_with?('https://jud.bennettlegal.com')
      end, 'no internal client/mixed-recipient link')
      check(message.subject.exclude?(record[:context]['reference']), 'no inserted client subject reference')
    end
  end

  def check_artwork(message, html, text, document:)
    check(html.text.include?('DocuSeal'), 'visible attribution')
    check(html.css('img').size == 6 && html.css('img').all? { |img| img['src'].start_with?('cid:') }, 'inline artwork')
    if document
      check(message.attachments['synthetic-document.pdf']&.body&.decoded == '%PDF synthetic JUD email fixture',
            'signed attachment retained')
    end
    check(text.exclude?('<style'), 'plain text has no stylesheet')
  end

  def recipient_matrix(record)
    client = record[:client]
    firm = record[:firm]
    mail(SubmitterMailer.invitation_email(firm), record, internal: true)
    mail(SubmitterMailer.invitation_email(client), record, internal: false)
    mail(SubmitterMailer.completed_email(firm, @user), record, internal: true, document: true)
    mail(SubmitterMailer.completed_email(firm, @user, to: firm.email), record, internal: true, document: true)
    mail(SubmitterMailer.completed_email(firm, @user, to: client.email), record, internal: false, document: true)
    mail(SubmitterMailer.completed_email(firm, @user, to: 'external@example.invalid'), record, internal: false,
                                                                                               document: true)
    mail(SubmitterMailer.documents_copy_email(firm, to: firm.friendly_name, sig: true), record, internal: true,
                                                                                                document: true)
    mail(SubmitterMailer.documents_copy_email(firm, to: client.friendly_name, sig: true), record, internal: false,
                                                                                                  document: true)
    mail(SubmitterMailer.documents_copy_email(firm, to: [client.friendly_name, firm.friendly_name].join(', ')), record,
         internal: false, document: true)
    mail(SubmitterMailer.declined_email(client, @user), record, internal: true)
  end

  def custom_invitation(record)
    body = ['Synthetic invitation body', "Client: #{record[:context]['client_name']}",
            "[Open in JUD](#{record[:context]['url']})", '[Sign]({submitter.link})'].join("\n\n")
    message = { 'subject' => "Synthetic invitation — #{record[:context]['reference']}",
                'body' => body }
    preferences = Submitters.normalize_preferences(@account, @user, { 'message' => message })
    record[:firm].update!(preferences: record[:firm].preferences.merge(preferences))
    mail(SubmitterMailer.invitation_email(record[:firm]), record, internal: true, custom: 'Synthetic invitation body')
  end

  def custom_body_matrix(record)
    record[:template].update!(preferences: {
                                'completed_notification_email_body' =>
                                  'Custom completion body: [Submission]({submission.link})',
                                'documents_copy_email_body' => 'Custom copy body: [Signed copy]({documents.link})'
                              })
    record[:firm].association(:template).reset
    record[:client].association(:template).reset
    mail(SubmitterMailer.completed_email(record[:firm], @user), record, internal: true, document: true,
                                                                        custom: 'Custom completion body')
    mail(SubmitterMailer.documents_copy_email(record[:firm], to: record[:firm].email),
         record, internal: true, document: true, custom: 'Custom copy body')
    mail(SubmitterMailer.documents_copy_email(record[:firm], to: record[:client].email),
         record, internal: false, document: true, custom: 'Custom copy body')
  end

  def set_context(record, context)
    record[:firm].update!(metadata: record[:firm].metadata.merge('bennett_jud_context' => context))
    record[:submission].submitters.reload
  end

  def invalid_context_matrix(record)
    invalid = [{ 'version' => 'unknown' }, { 'issuance_id' => SecureRandom.uuid },
               { 'url' => 'https://evil.example.invalid/solar/cases/9123' },
               { 'url' => 'https://jud.bennettlegal.com@evil.example.invalid/solar/cases/9123' },
               { 'url' => 'https://jud.bennettlegal.com/solar/cases/9123?token=synthetic' },
               { 'url' => 'https://jud.bennettlegal.com/intake/leads#wrong-record' }, { 'record_type' => 'unknown' },
               { 'reference' => "LEAD-2099-1\nBcc: external@example.invalid" }, { 'extra' => 'ignored' }]
    invalid.each do |change|
      set_context(record, record[:context].merge(change))
      mail(SubmitterMailer.completed_email(record[:firm], @user), record, internal: false, document: true)
    end
    set_context(record, record[:context])
    original = record[:firm].external_id
    record[:firm].update!(external_id: 'unbound-firm')
    record[:submission].submitters.reload
    mail(SubmitterMailer.completed_email(record[:firm], @user), record, internal: false, document: true)
    record[:firm].update!(external_id: original)
    record[:submission].submitters.reload
  end

  def grouping(record)
    original = SubmitterMailer.method(:documents_copy_email)
    captured = []
    delivery = Object.new
    delivery.define_singleton_method(:deliver_later!) { true }
    SubmitterMailer.define_singleton_method(:documents_copy_email) do |_submitter, to:|
      captured << to
      delivery
    end
    config = Struct.new(:value).new({ 'bcc_recipients' => false })
    job = ProcessSubmitterCompletionJob.new
    job.send(:enqueue_copy_emails, record[:firm], config)
    emails = captured.map { |to| Mail::Address.new(to).address }.sort
    check(emails == [record[:client].email, record[:firm].email].sort, 'separate copies for both original recipients')
    set_context(record, nil)
    captured.clear
    job.send(:enqueue_copy_emails, record[:firm], config)
    check(captured.size == 1 && Mail::AddressList.new(captured.first).addresses.size == 2,
          'original grouping without JUD context')
  ensure
    SubmitterMailer.define_singleton_method(:documents_copy_email) { |*args, **kwargs| original.call(*args, **kwargs) }
    set_context(record, record[:context])
  end

  def literal_text(record)
    context = record[:context].merge('client_name' => '<b>{sender.email}</b> [Open](https://evil.example.invalid)')
    set_context(record, context)
    mail(SubmitterMailer.documents_copy_email(record[:firm], to: record[:firm].email), record.merge(context:),
         internal: true, document: true)
    set_context(record, record[:context])
    context = BennettJudEmailContext.for_submission(record[:submission])
    subject = BennettJudEmailContext.subject("Already — #{record[:context]['reference']}", context)
    check(subject.scan(record[:context]['reference']).size == 1, 'subject reference not duplicated')
  end

  def api_metadata(record)
    metadata = { 'lang' => 'en', 'bennett_consent_version' => 'synthetic-v1',
                 'bennett_jud_context' => record[:context] }
    controller = Api::SubmissionsController.new
    controller.params = ActionController::Parameters.new({ 'submitters' => [{ 'role' => 'Attorney',
                                                                              'metadata' => metadata }] })
    check(controller.send(:submissions_params).to_h.dig('submitters', 0, 'metadata') == metadata,
          'API admits nested context and consent metadata unchanged')
    serialized = Submitters::SerializeForApi.call(record[:firm], with_values: false, with_documents: false)
    check(serialized.dig('metadata', 'bennett_jud_context') == record[:context], 'API returns the exact stored context')
  end

  def invalid_staff_configuration(record)
    host = ENV.fetch('BENNETT_STAFF_ACCESS_HOST')
    ENV['BENNETT_STAFF_ACCESS_HOST'] = 'https://invalid-host.example.invalid'
    check(BennettMailerLinks.submission_url(record[:submission]).nil?, 'invalid staff host is not linked')
    mail(SubmitterMailer.completed_email(record[:firm], @user), record, internal: true, document: true)
    mail(SubmitterMailer.documents_copy_email(record[:firm], to: record[:firm].email), record, internal: true,
                                                                                               document: true)
  ensure
    ENV['BENNETT_STAFF_ACCESS_HOST'] = host
  end

  def run
    LANGUAGES.each do |language|
      @account.update!(locale: language)
      KINDS.each do |kind|
        record = build(language, kind)
        recipient_matrix(record)
        custom_invitation(record)
        custom_body_matrix(record)
        grouping(record)
        literal_text(record)
        api_metadata(record)
      end
    end
    invalid_context_matrix(build('en', 'lead'))
    early = build('en', 'lead', finished: false)
    early[:client].update!(declined_at: Time.current)
    mail(SubmitterMailer.declined_email(early[:client], @user), early, internal: true)
    invalid_staff_configuration(build('en', 'case'))
    check(@staff_links >= 8, 'staff-host checks exercised on actual messages')
  end
end

ActiveRecord::Base.transaction do
  fixture = JudEmailContextFixture.new
  fixture.run
  puts({ jud_email_context: 'passed', checks: fixture.checks, messages: fixture.messages, delivered: false }.to_json)
  raise ActiveRecord::Rollback
end
