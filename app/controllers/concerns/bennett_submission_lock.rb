# frozen_string_literal: true

# Modified by Bennett Legal on 2026-11-13: serialize signer mutations with API expiry.

module BennettSubmissionLock
  private

  def with_bennett_submission_lock
    submitter = @submitter || Submitter.find_by(slug: params[:slug] || params[:submit_form_slug])

    return yield unless submitter

    @submitter = submitter
    submission = submitter.submission

    # Reload both records after acquiring the common lock. Keep it through the
    # action's commit so stale browser requests cannot write after API expiry.
    submission.with_lock do
      @submitter.reload
      @submitter.submission = submission

      yield
    end
  end
end
