# frozen_string_literal: true

# Presentation only. Native account permissions continue to own every action.
module BennettStaffHelper
  PRACTICE_DOCUMENT_PREFIX = /\APRACTICE\s*[—–-]\s*NOT A CONTRACT\s*[—–-]\s*/i

  def bennett_staff_practice_document?(name)
    name.to_s.match?(PRACTICE_DOCUMENT_PREFIX)
  end

  def bennett_staff_document_title(name)
    name.to_s.sub(PRACTICE_DOCUMENT_PREFIX, '')
  end

  # Retainer exports carry a language marker in their document name. Prefer
  # the submission's frozen schema over today's editable template. Older
  # Bennett imports used the Spanish contract heading as the template name.
  def bennett_staff_document_language(template:, submission: nil)
    schema = Array(submission&.template_schema)
    schema = Array(template&.schema) if schema.empty?
    languages = schema.filter_map do |document|
      next unless document.is_a?(Hash)

      match = document['name'].to_s.match(/\Aretainer[-_](en|es)(?:[-_.]|\z)/i)
      match[1].downcase if match
    end.uniq
    return languages.first if languages.one?
    return if languages.size > 1

    name = submission&.name.to_s
    name = template&.name.to_s if name.empty?
    name = bennett_staff_document_title(name)
    'es' if name.match?(/\AContrato de Empleo y Acuerdo de Honorarios\z/i)
  end

  def bennett_staff_section
    return 'submissions' if controller_name == 'submissions_dashboard'

    case request.path
    when %r{\A/(?:settings|users|user_signature|user_initials|mfa_setup)(?:/|\z)} then 'settings'
    when %r{\A/(?:submissions|submitters)(?:/|\z)} then 'submissions'
    else 'templates'
    end
  end

  def bennett_staff_title(template: nil, submission: nil)
    return 'Signing access' unless bennett_staff_signed_in?
    return 'Template editor' if template&.persisted? && request.path.end_with?('/edit')
    if submission&.persisted?
      return bennett_staff_document_title(submission.name.presence || submission.template&.name || 'Submission')
    end
    return bennett_staff_document_title(template.name) if template&.persisted?

    case bennett_staff_section
    when 'settings'
      names = { 'profile' => 'Profile', 'account' => 'Account', 'email' => 'Email', 'storage' => 'Storage',
                'sms' => 'SMS', 'notifications' => 'Notifications', 'esign' => 'Electronic signatures',
                'personalization' => 'Personalization', 'users' => 'Users', 'api' => 'API access',
                'webhooks' => 'Webhooks', 'sso' => 'Single sign-on', 'mcp' => 'MCP connections' }
      names.fetch(request.path.split('/')[2], 'Settings')
    when 'submissions'
      params[:status] == 'completed' ? 'Completed submissions' : 'Submissions'
    else
      request.path.end_with?('/new') ? 'Create template' : 'Templates'
    end
  end

  def bennett_staff_description
    return 'Use your Bennett Legal staff access to open the signing workspace.' unless bennett_staff_signed_in?

    case bennett_staff_section
    when 'settings' then 'Manage your profile, signing preferences and workspace connections.'
    when 'submissions' then 'Follow signatures, open documents and review the complete event history.'
    else 'Prepare documents and manage the versions used for signing.'
    end
  end
end
