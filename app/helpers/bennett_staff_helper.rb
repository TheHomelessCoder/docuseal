# frozen_string_literal: true

# Presentation only. Native account permissions continue to own every action.
module BennettStaffHelper
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
    return submission.name.presence || submission.template&.name || 'Submission' if submission&.persisted?
    return template.name if template&.persisted?

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
