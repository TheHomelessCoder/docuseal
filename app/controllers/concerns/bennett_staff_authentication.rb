# frozen_string_literal: true

module BennettStaffAuthentication
  extend ActiveSupport::Concern

  included do
    prepend_before_action :authenticate_bennett_staff!
    helper_method :bennett_staff?, :bennett_staff_password_required?, :bennett_staff_signed_in?

    rescue_from Bennett::StaffAccess::Denied do
      render 'staff_access/denied', status: :forbidden
    end
  end

  private

  def bennett_staff?
    Bennett::StaffAccess.enabled? && request.host == Bennett::StaffAccess.configuration.host
  end

  def bennett_staff_password_required?
    @bennett_staff_user&.otp_required_for_login?
  end

  def bennett_staff_signed_in?
    warden.user(:user).present?
  end

  def authenticate_bennett_staff!
    return unless bennett_staff?

    email = Bennett::StaffAccess.verifier.email(request.headers['Cf-Access-Jwt-Assertion'])
    @bennett_staff_user = User.active.find_by(email:) if email
    unless @bennett_staff_user&.active_for_authentication?
      sign_out
      reset_session
      raise Bennett::StaffAccess::Denied
    end

    # Inspect an existing session without running Devise's password/TOTP
    # strategies ahead of Rails' CSRF check on the native MFA form.
    if (session_user = warden.user(:user))
      return if session_user.id == @bennett_staff_user.id

      sign_out
      reset_session
    end
    return if bennett_staff_password_required?

    reset_session
    # A configured native authenticator remains an additional requirement.
    # Its existing Devise challenge must complete before a session is issued.
    sign_in(:user, @bennett_staff_user)
  end
end
