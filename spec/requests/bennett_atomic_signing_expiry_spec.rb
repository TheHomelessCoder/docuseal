# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

describe 'Bennett atomic signing and unsigned expiry' do
  # Separate requests must observe actual commits on separate DB connections.
  self.use_transactional_tests = false

  attr_reader :account, :author, :template, :submission, :submitter, :token, :threads, :releases

  before do
    skip 'Row-lock race proof requires PostgreSQL' unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'

    @account = create(:account)
    @author = create(:user, account: account)
    @template = create(:template, account: account, author: author, only_field_types: %w[signature])
    @submission = create(:submission, :with_submitters, template: template, created_by_user: author)
    @submitter = submission.submitters.first
    @token = author.access_token.token
    @threads = []
    @releases = []
  end

  after do
    releases&.each { |queue| queue << true }
    threads&.each { |thread| thread.join(10) || thread.kill }
    submission&.destroy!
    template&.destroy!
    author&.destroy!
    account&.destroy!
  end

  it 'advertises the capability on the actual submission read and expires unsigned submissions' do
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get "/api/submissions/#{submission.id}", headers: api_headers
    expect(session.response.parsed_body['bennett_atomic_signing_expiry']).to be(true)

    expire(session, unsigned_only: true)

    expect(session.response).to have_http_status(:ok)
    expect(session.response.parsed_body['status']).to eq('expired')
    expect(submission.reload).to be_expired
  end

  %i[completed_at declined_at].each do |attribute|
    it "refuses unsigned expiry after #{attribute}, without changing expiry or name" do
      submitter.update!(attribute => Time.current)
      original_expiry = 1.week.from_now.change(usec: 0)
      submission.update!(expire_at: original_expiry)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.put "/api/submissions/#{submission.id}", headers: api_headers,
                                                       params: { expire_at: 1.minute.ago.iso8601,
                                                                 name: 'Must not apply',
                                                                 bennett_unsigned_only: true }.to_json

      expect(session.response).to have_http_status(:conflict)
      expect(session.response.parsed_body).to eq('error' => 'BENNETT_UNSIGNED_EXPIRY_REFUSED')
      expect(submission.reload.expire_at).to eq(original_expiry)
      expect(submission.name).not_to eq('Must not apply')
    end
  end

  it 'retains ordinary expiry for a signed submission when the flag is absent' do
    submitter.update!(completed_at: Time.current)
    session = ActionDispatch::Integration::Session.new(Rails.application)

    expire(session)

    expect(session.response).to have_http_status(:ok)
    expect(submission.reload).to be_expired
  end

  it 'lets an in-flight signing commit first and then refuses unsigned expiry' do
    gate = install_lock_gate
    signing, signing_pid = start_request(gate:) { |session| sign(session) }
    Timeout.timeout(10) { gate[:locked].pop }
    expiry, expiry_pid = start_request { |session| expire(session, unsigned_only: true) }

    expect_blocked(expiry_pid, signing_pid)
    gate[:release] << true

    expect(signing.value.first).to eq(200)
    expect(expiry.value).to eq([409, { 'error' => 'BENNETT_UNSIGNED_EXPIRY_REFUSED' }])
    expect(submission.reload.expire_at).to be_nil
    expect(submitter.reload.completed_at).to be_present
    expect(submitter.values.values).to include('synthetic-signature-uuid')
  end

  %i[completion values decline api_completion invite upload prefill delegate].each do |mutation|
    it "commits expiry first and refuses a stale #{mutation} request waiting on the lock" do
      gate = install_lock_gate
      expiry, expiry_pid = start_request(gate:) { |session| expire(session, unsigned_only: true) }
      Timeout.timeout(10) { gate[:locked].pop }
      signing, signing_pid = start_request do |session|
        case mutation
        when :decline
          session.post "/s/#{submitter.slug}/decline", params: { reason: 'Synthetic decline' }
        when :api_completion
          session.put "/api/submitters/#{submitter.id}", headers: api_headers, params: { completed: true }.to_json
        when :invite, :upload, :delegate
          session.post "/s/#{submitter.slug}/#{mutation}"
        when :prefill
          session.post "/s/#{submitter.slug}/prefill_attachments"
        else
          sign(session, completed: mutation == :completion)
        end
      end

      expect_blocked(signing_pid, expiry_pid)
      gate[:release] << true

      expect(expiry.value.first).to eq(200)
      expect(signing.value.first).to eq(mutation.in?(%i[decline delegate]) ? 302 : 422)
      expect(submission.reload).to be_expired
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.declined_at).to be_nil
      expect(submitter.values).to eq({})
      events = submitter.submission_events.where(event_type: %w[complete_form api_complete_form decline_form])
      expect(events).not_to exist
    end
  end

  it 'dispatches public completion, webhook bulk and reindex bulk work with committed signing state' do
    observations = observe_completion_dispatch
    webhook = Struct.new(:id, :events).new(123, ['form.started'])
    allow(WebhookUrls).to receive(:for_account_id).with(account.id, 'form.started').and_return([webhook])
    bulk_webhooks = []
    bulk_reindexes = []
    allow(Sidekiq::Client).to receive(:push_bulk) do |payload|
      bulk_webhooks << [payload, worker_state(submitter.id)]
      []
    end
    allow(ReindexSearchEntryJob).to receive(:perform_bulk) do |args|
      bulk_reindexes << [args, worker_state(submitter.id)]
      []
    end

    session = ActionDispatch::Integration::Session.new(Rails.application)
    sign(session)

    expect(session.response).to have_http_status(:ok)
    expect(observations.first[:args]).to eq('submitter_id' => submitter.id, 'is_last' => true)
    expect(bulk_webhooks.first.first['class']).to eq(SendFormStartedWebhookRequestJob)
    expect(bulk_webhooks.first.first['args'].first.first).to include('submitter_id' => submitter.id,
                                                                     'webhook_url_id' => webhook.id,
                                                                     'event_uuid' => a_kind_of(String))
    expect(bulk_reindexes.first.first).to eq([[{ 'record_type' => 'Submitter', 'record_id' => submitter.id }]])
    states = [observations.first[:state], bulk_webhooks.first.last, bulk_reindexes.first.last]
    states.each do |state|
      expect(state[:completed_at]).to be_present
      expect(state[:submission_completed_at]).to be_present
      expect(state[:values].values).to include('synthetic-signature-uuid')
    end
  end

  it 'dispatches API completion only after the updated signer commits' do
    observations = observe_completion_dispatch
    session = ActionDispatch::Integration::Session.new(Rails.application)

    session.put "/api/submitters/#{submitter.id}", headers: api_headers,
                                                   params: { completed: true, name: 'Committed API signer' }.to_json

    expect(session.response).to have_http_status(:ok)
    expect(observations.first[:args]).to eq('submitter_id' => submitter.id, 'is_last' => true)
    expect(observations.first[:state][:completed_at]).to be_present
    expect(observations.first[:state][:submission_completed_at]).to be_present
    expect(observations.first[:state][:name]).to eq('Committed API signer')
  end

  it 'dispatches API invitations only after the new recipient commits' do
    observations = observe_invitation_dispatch
    session = ActionDispatch::Integration::Session.new(Rails.application)
    attrs = { email: 'api-recipient@example.invalid', send_email: true }

    session.put "/api/submitters/#{submitter.id}", headers: api_headers, params: attrs.to_json

    expect(session.response).to have_http_status(:ok)
    expect(observations.first[:args]).to eq('submitter_id' => submitter.id)
    expect(observations.first[:state][:email]).to eq('api-recipient@example.invalid')
  end

  it 'dispatches delegated invitations with the committed replacement email and slug' do
    observations = observe_invitation_dispatch
    account.account_configs.create!(key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
    old_slug = submitter.slug
    session = ActionDispatch::Integration::Session.new(Rails.application)

    session.post "/s/#{old_slug}/delegate", params: { email: 'delegated@example.invalid' }

    expect(session.response).to have_http_status(:found)
    expect(observations.first[:args]).to eq('submitter_id' => submitter.id)
    expect(observations.first[:state][:email]).to eq('delegated@example.invalid')
    expect(observations.first[:state][:slug]).not_to eq(old_slug)
    expect(submitter.reload.slug).to eq(observations.first[:state][:slug])
    expect(submitter.submitter_versions.pluck(:slug)).to eq([old_slug])
  end

  it 'dispatches decline mail and webhook bulk work only after decline commits' do
    allow(Users).to receive(:send_emails?).and_return(true)
    observations = []
    mail = instance_double(ActionMailer::MessageDelivery)
    allow(SubmitterMailer).to receive(:declined_email).and_return(mail)
    allow(mail).to receive(:deliver_later!) { observations << worker_state(submitter.id) }
    webhook = Struct.new(:id, :events).new(123, ['form.declined'])
    allow(WebhookUrls).to receive(:for_account_id).with(account.id, 'form.declined').and_return([webhook])
    allow(Sidekiq::Client).to receive(:push_bulk) do |_payload|
      observations << worker_state(submitter.id)
      []
    end
    session = ActionDispatch::Integration::Session.new(Rails.application)

    session.post "/s/#{submitter.slug}/decline", params: { reason: 'Synthetic decline' }

    expect(session.response).to have_http_status(:found)
    expect(observations.size).to eq(2)
    expect(observations.pluck(:declined_at)).to all(be_present)
  end

  %i[completion api_completion delegate decline].each do |mutation|
    it "drops #{mutation} dispatch if an enclosing transaction rolls back" do
      account.account_configs.create!(key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
      allow(Users).to receive(:send_emails?).and_return(false)
      allow(ProcessSubmitterCompletionJob).to receive(:perform_async)
      allow(SendSubmitterInvitationEmailJob).to receive(:perform_async)
      allow(WebhookUrls).to receive(:enqueue_events).and_call_original
      allow(SearchEntries).to receive(:enqueue_reindex).and_call_original
      original_email = submitter.email
      original_slug = submitter.slug

      ApplicationRecord.transaction do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        case mutation
        when :api_completion
          session.put "/api/submitters/#{submitter.id}", headers: api_headers, params: { completed: true }.to_json
        when :delegate
          session.post "/s/#{original_slug}/delegate", params: { email: 'rollback@example.invalid' }
        when :decline
          session.post "/s/#{original_slug}/decline", params: { reason: 'Rolled back' }
        else
          sign(session)
        end
        expect(session.response.status).to eq(mutation.in?(%i[delegate decline]) ? 302 : 200)
        expect(ProcessSubmitterCompletionJob).not_to have_received(:perform_async)
        expect(SendSubmitterInvitationEmailJob).not_to have_received(:perform_async)
        expect(WebhookUrls).not_to have_received(:enqueue_events)
        expect(SearchEntries).not_to have_received(:enqueue_reindex)
        raise ActiveRecord::Rollback
      end

      expect(ProcessSubmitterCompletionJob).not_to have_received(:perform_async)
      expect(SendSubmitterInvitationEmailJob).not_to have_received(:perform_async)
      expect(WebhookUrls).not_to have_received(:enqueue_events)
      expect(SearchEntries).not_to have_received(:enqueue_reindex)
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.declined_at).to be_nil
      expect(submitter.email).to eq(original_email)
      expect(submitter.slug).to eq(original_slug)
      expect(submitter.submission_events).not_to exist
    end
  end

  private

  def observe_completion_dispatch
    observations = []
    allow(ProcessSubmitterCompletionJob).to receive(:perform_async) do |args|
      observations << { args:, state: worker_state(args.fetch('submitter_id')) }
    end
    observations
  end

  def observe_invitation_dispatch
    observations = []
    allow(SendSubmitterInvitationEmailJob).to receive(:perform_async) do |args|
      observations << { args:, state: worker_state(args.fetch('submitter_id')) }
    end
    observations
  end

  def worker_state(submitter_id)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        signer = Submitter.find(submitter_id)
        signer.attributes.symbolize_keys.slice(:completed_at, :declined_at, :values, :name, :email, :slug)
              .merge(submission_completed_at: signer.submission.completed_at)
      end
    end.value
  end

  def api_headers
    { 'x-auth-token' => token, 'content-type' => 'application/json' }
  end

  def expire(session, unsigned_only: false)
    attrs = { expire_at: 1.minute.ago.iso8601 }
    attrs[:bennett_unsigned_only] = true if unsigned_only
    session.put "/api/submissions/#{submission.id}", headers: api_headers, params: attrs.to_json
  end

  def sign(session, completed: true)
    field_uuid = submission.template_fields.first.fetch('uuid')
    session.put "/s/#{submitter.slug}", params: { completed: completed.to_s,
                                                  values: { field_uuid => 'synthetic-signature-uuid' } }
  end

  def install_lock_gate
    gate = { locked: Queue.new, release: Queue.new }
    releases << gate[:release]
    allow_any_instance_of(Submission).to receive(:lock!).and_wrap_original do |original, *args|
      original.call(*args).tap do
        next unless Thread.current[:bennett_atomic_gate] == gate

        gate[:locked] << true
        Timeout.timeout(10) { gate[:release].pop }
      end
    end
    gate
  end

  def start_request(gate: nil)
    ready = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:bennett_atomic_gate] = gate
        ready << connection.select_value('SELECT pg_backend_pid()').to_i
        session = ActionDispatch::Integration::Session.new(Rails.application)
        yield session
        [session.response.status, session.response.parsed_body]
      end
    end
    threads << thread
    [thread, Timeout.timeout(10) { ready.pop }]
  end

  def expect_blocked(waiting_pid, holding_pid)
    Timeout.timeout(10) do
      loop do
        blocked = ActiveRecord::Base.connection.select_value(
          "SELECT #{holding_pid} = ANY(pg_blocking_pids(#{waiting_pid}))"
        )
        break if blocked

        sleep 0.01
      end
    end
  end
end
