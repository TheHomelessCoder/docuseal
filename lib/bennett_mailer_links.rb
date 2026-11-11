# frozen_string_literal: true

# Bennett Legal, 2026-11-10: administration links belong on the Access-protected
# staff host. Signing and completed-document links retain their public host.
module BennettMailerLinks
  module_function

  def submission_url(submission)
    options = Docuseal.default_url_options
    if Bennett::StaffAccess.enabled?
      options = options.merge(host: Bennett::StaffAccess.configuration.host, protocol: 'https', port: nil)
    end
    Rails.application.routes.url_helpers.submission_url(submission, **options)
  rescue Bennett::StaffAccess::ConfigurationError
    # An invalid staff selection must not suppress completed-document mail or
    # produce a link to an unvalidated host. The JUD record link remains usable.
    nil
  end
end
