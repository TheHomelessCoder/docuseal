# frozen_string_literal: true

# Modified by Bennett Legal on 2026-11-01: enforce upstream recipient-order authorization before mutations.
# Modified by Bennett Legal on 2026-11-13: serialize signature attachments with API expiry.

class SubmitFormPrefillAttachmentsController < ActionController::API
  include BennettSubmissionLock
  include ActionController::Cookies
  include ActiveStorage::SetCurrent

  around_action :with_bennett_submission_lock, only: :create

  def create
    @submitter = Submitter.find_by!(slug: params[:submit_form_slug])

    unless can_upload?(@submitter)
      return render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
    end

    unless Submitters::AuthorizedForForm.call(@submitter, current_user, request, with_order: true)
      return render json: { error: I18n.t('verification_required_refresh_the_page_and_pass_2fa') },
                    status: :unprocessable_content
    end

    uuid, slug = ApplicationRecord.signed_id_verifier.verify(params[:prefill_token], purpose: :prefill_attachment)

    raise ActiveRecord::RecordNotFound if slug != @submitter.slug

    source_attachment = ActiveStorage::Attachment.find_by!(uuid:)

    attachment = @submitter.attachments_attachments.find_or_create_by!(blob_id: source_attachment.blob_id)

    render json: attachment.as_json(only: %i[uuid created_at], methods: %i[url filename content_type])
  end

  private

  def can_upload?(submitter)
    !submitter.viewer? &&
      !submitter.declined_at? &&
      !submitter.completed_at? &&
      !submitter.submission.archived_at? &&
      !submitter.submission.expired? &&
      !submitter.submission.template&.archived_at?
  end
end
