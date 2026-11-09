# frozen_string_literal: true

class SessionsController < Devise::SessionsController
  before_action :configure_permitted_parameters

  skip_before_action :verify_authenticity_token, if: -> { request.xhr? && request.format.json? }

  respond_to :json, only: :create

  around_action :with_browser_locale

  def new
    return redirect_to submissions_path if bennett_staff? && !bennett_staff_password_required?

    super
  end

  def create
    if bennett_staff?
      return redirect_to submissions_path if !bennett_staff_password_required? || bennett_staff_signed_in?

      raise Bennett::StaffAccess::Denied unless sign_in_params[:email].to_s.downcase == @bennett_staff_user.email
    end

    email = sign_in_params[:email].to_s.downcase

    if Docuseal.multitenant? && !User.exists?(email:)
      Rollbar.warning('Sign in new user') if defined?(Rollbar)

      respond_to do |format|
        format.html do
          redirect_to new_registration_path(sign_up: true, user: sign_in_params.slice(:email)),
                      notice: t('create_a_new_account')
        end
        format.json do
          render json: { sign_up: true, notice: t('create_a_new_account') }, status: :unprocessable_content
        end
      end

      return
    end

    if User.exists?(email:, otp_required_for_login: true) && sign_in_params[:otp_attempt].blank?
      respond_to do |format|
        format.html { render :otp, locals: { resource: User.new(sign_in_params) }, status: :unprocessable_content }
        format.json { render json: { otp_required: true, email_otp: false }, status: :unprocessable_content }
      end

      return
    end

    super
  end

  private

  def require_no_authentication
    return if bennett_staff?

    super
  end

  def after_sign_out_path_for(*)
    return '/cdn-cgi/access/logout' if bennett_staff?

    super
  end

  def after_sign_in_path_for(...)
    return submissions_path if bennett_staff?

    if params[:redir].present?
      return console_redirect_index_path(redir: params[:redir]) if params[:redir].starts_with?(Docuseal::CONSOLE_URL)

      return params[:redir]
    end

    super
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:otp_attempt])
  end

  def set_flash_message(key, kind, options = {})
    return if key == :alert && kind == 'already_authenticated'

    super
  end
end
