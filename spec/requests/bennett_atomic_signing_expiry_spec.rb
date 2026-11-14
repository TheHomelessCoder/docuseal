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

  private

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
