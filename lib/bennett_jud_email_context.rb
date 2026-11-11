# frozen_string_literal: true

require 'uri'

# Bennett Legal, 2026-11-10: internal JUD context for native staff mail.
# The context is informational; it never grants access or changes recipients.
module BennettJudEmailContext
  VERSION = 'jud-retainer-email/1'
  UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i
  KEYS = %w[client_name issuance_id record_type reference url version].freeze

  module_function

  def for_submission(submission)
    firm, issuance = firm_identity(submission)
    return unless firm

    data = firm.metadata['bennett_jud_context'] if firm.metadata.is_a?(Hash)
    return unless valid_context?(data, issuance)

    { record_type: data['record_type'], reference: data['reference'], url: data['url'],
      client_name: data['client_name'], firm_email: firm.email.downcase, firm_uuid: firm.uuid }
  end

  def firm_identity(submission)
    return unless submission.variables.is_a?(Hash)

    issuance = submission.variables['bennett_issuance_id']
    return unless issuance.is_a?(String) && UUID.match?(issuance) && submission.submitters_order_preserved?

    roles = submission.template_submitters
    signers = submission.submitters.to_a
    return unless roles.is_a?(Array) && roles.size == 2 && roles[1].is_a?(Hash) && signers.size == 2

    firms = signers.select { |s| s.uuid == roles[1]['uuid'] && s.external_id == "#{issuance}:1" }
    [firms.first, issuance] if firms.one? && firms.first.email.present?
  end

  def valid_context?(data, issuance)
    data.is_a?(Hash) && data.keys.sort == KEYS && data['version'] == VERSION && data['issuance_id'] == issuance &&
      text?(data['client_name'],
            500) && text?(data['reference'], 200) && text?(data['url'], 1500) && valid_record_url?(data)
  end

  def for_recipients(submitter, recipients)
    context = for_submission(submitter.submission)
    return unless context

    emails = Mail::AddressList.new(Array(recipients).join(', ')).addresses.filter_map { |address| address.address&.downcase }
    return if emails.empty?

    clients = submitter.submission.submitters.reject { |s| s.uuid == context[:firm_uuid] }
    client_emails = clients.filter_map { |s| s.email&.downcase }
    staff_emails = submitter.account.users.active.where.not(role: 'integration').pluck(:email).map(&:downcase)
    allowed = ([context[:firm_email]] + staff_emails) - client_emails
    context if emails.all? { |email| allowed.include?(email) }
  rescue Mail::Field::ParseError
    nil
  end

  def subject(subject, context)
    return subject unless context && subject.to_s.exclude?(context[:reference])

    "#{subject} — #{context[:reference]}"
  end

  def text?(value, maximum)
    value.is_a?(String) && value.present? && value.size <= maximum && !value.match?(/[\p{Cc}\p{Cf}]/)
  end

  def valid_record_url?(data)
    uri = URI.parse(data['url'])
    unless uri.scheme == 'https' && uri.host == 'jud.bennettlegal.com' && uri.port == 443 && !uri.userinfo && !uri.query
      return false
    end

    if data['record_type'] == 'case'
      !uri.fragment && uri.path.match?(%r{\A/solar/cases/[1-9]\d{0,15}\z})
    elsif data['record_type'] == 'lead'
      uri.path == '/intake/leads' && uri.fragment.present? &&
        URI::DEFAULT_PARSER.unescape(uri.fragment) == data['reference']
    else
      false
    end
  rescue URI::InvalidURIError
    false
  end
end
