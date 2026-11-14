# frozen_string_literal: true

# Runs only against the CI stack's synthetic account, inside a rolled-back
# transaction. Exercises production Rails middleware, Devise, cookies and CSRF
# with real RSA-signed assertions; only the certificate fetch is substituted.
require 'action_dispatch/testing/integration'
require 'jwt'
require 'nokogiri'

raise 'Synthetic CI stack required' unless ENV['APP_URL'] == 'https://sign.ci.test' &&
                                           Account.first&.name == 'Bennett Legal (smoke test)'

ENV['BENNETT_STAFF_ACCESS_ENABLED'] = 'true'
ENV['BENNETT_STAFF_ACCESS_HOST'] = 'sign-staff.ci.test'
ENV['BENNETT_STAFF_ACCESS_TEAM'] = 'ci-team'
ENV['BENNETT_STAFF_ACCESS_AUD'] = 'a' * 64

key = OpenSSL::PKey::RSA.generate(2048)
jwk = JWT::JWK.new(key, 'ci-staff-key')
config = Bennett::StaffAccess.configuration
verifier = Bennett::StaffAccess::Verifier.new(team: config.team, audience: config.audience,
                                              fetch_keys: -> { { 'keys' => [JSON.parse(jwk.export.to_json)] } })
Bennett::StaffAccess.instance_variable_set(:@verifier, verifier)
Bennett::StaffAccess.instance_variable_set(:@verifier_config, config)

checks = 0
check = lambda do |condition, label|
  raise "Staff access failed: #{label}" unless condition

  checks += 1
end
make_token = lambda do |email, changes = {}|
  claims = { iss: 'https://ci-team.cloudflareaccess.com', aud: [config.audience],
             iat: Time.now.to_i, exp: Time.now.to_i + 300,
             sub: 'ci-staff-identity', type: 'app', email: }.merge(changes)
  JWT.encode(claims, key, 'RS256', kid: jwk.kid)
end
new_browser = lambda do |host = config.host|
  browser = ActionDispatch::Integration::Session.new(Rails.application)
  browser.host! host
  browser.https!
  browser
end
csrf = lambda do |browser|
  Nokogiri::HTML(browser.response.body).at_css('meta[name="csrf-token"]')&.[]('content')
end

redirects_to = lambda do |browser, path|
  browser.response.redirect? && URI(browser.response.location).path == path
end
original_count = User.count
# The acceptance requests share one rollback transaction; no synthetic data survives.
User.transaction do
  user = User.first
  headers = { 'Cf-Access-Jwt-Assertion' => make_token.call(user.email) }
  browser = new_browser.call
  browser.get('/sign_in', params: { redir: 'https://attacker.invalid' }, headers:)
  check.call(redirects_to.call(browser, '/submissions'), 'passwordless landing')
  browser.get('/submissions', headers:)
  check.call(browser.response.status == 200, 'existing account session')
  body = browser.response.body
  check.call(body.include?('JUD retainers') && body.include?('bennett-staff-v1.css'), 'staff shell')
  check.call(body.include?('DocuSeal') && body.exclude?('name="user[password]"'), 'no password prompt and attribution')

  # Every native staff section must render the shared workspace, including
  # settings pages and the full-page document/builder layouts.
  paths = %w[/templates /submissions?status=completed /settings/profile /settings/account
             /settings/notifications /settings/esign /settings/personalization /settings/users
             /settings/api /settings/webhooks /settings/storage /settings/email /settings/sms /settings/sso]
  template = Template.create!(account: user.account, author: user, name: 'Staff workspace (synthetic)')
  paths.push("/templates/#{template.id}", "/templates/#{template.id}/edit")
  paths.each do |path|
    browser.get(path, headers:)
    check.call(browser.response.status == 200, "workspace section #{path}")
    section = Nokogiri::HTML(browser.response.body)
    check.call(section.at_css('.bennett-staff-page-heading h1').present?, "page heading #{path}")
    check.call(section.at_css('.bennett-staff-nav [aria-current="page"]').present?, "active navigation #{path}")
    check.call(section.css('link[href="/packs/bennett-staff-v1.css?v=7"]').one?, "versioned workspace styles #{path}")
  end

  # Small/empty lists used to hide search and offer a document upload instead.
  # Keep fixtures rolled back separately so the authentication checks below
  # retain their original account/user counts.
  Submission.transaction(requires_new: true) do
    role = { 'name' => 'Client', 'uuid' => SecureRandom.uuid }
    template.update!(submitters: [role])
    SearchEntries.reindex_record(template) if Docuseal.fulltext_search?
    create_submission = lambda do |name, status = :completed, source_template = template|
      completed_at = Time.current if status == :completed
      record = source_template.submissions.create!(account: source_template.account, created_by_user: user,
                                                   source: 'api', template_submitters: [role],
                                                   completed_at:, archived_at: (Time.current if status == :archived))
      record.submitters.create!(account: source_template.account, uuid: role['uuid'], name:,
                                email: "#{SecureRandom.hex(6)}@example.test", sent_at: Time.current, completed_at:)
      SearchEntries.reindex_record(record) if Docuseal.fulltext_search?
      record
    end
    target = create_submission.call('Anchor Reviewer')
    create_submission.call('Anchor Pending', :pending)
    archived = create_submission.call('Anchor Archived', :archived)
    rows = -> { Nokogiri::HTML(browser.response.body).css('.bennett-submission-item').pluck('id') }
    list_paths = ['/submissions', '/submissions?status=completed', '/submissions/archived',
                  "/templates/#{template.id}", "/templates/#{template.id}/archived"]
    list_paths.each do |path|
      browser.get(path, headers:)
      page = Nokogiri::HTML(browser.response.body)
      check.call(browser.response.status == 200, "small submission list #{path}")
      check.call(page.at_css('input[type="search"][aria-label="Search submissions"]').present?,
                 "visible search #{path}")
      check.call(page.at_css('.bennett-submission-filters').present?, "available filters #{path}")
    end
    browser.get('/submissions', headers:)
    page = Nokogiri::HTML(browser.response.body)
    check.call(page.css('file-dropzone, a[href="/templates/new"]').empty?,
               'staff dashboard has no upload/create prompt')

    # The target is older than an entire page of newer records. Its match must
    # come from the authorized query, rather than filtering the rendered page.
    12.times { create_submission.call('Filler Reviewer') }
    other_account = Account.create!(name: 'Other synthetic account')
    other_user = other_account.users.create!(first_name: 'Private', last_name: 'Reviewer',
                                             email: 'private@example.test', password: SecureRandom.hex(24))
    other_template = Template.create!(account: other_account, author: other_user, name: 'Private template',
                                      submitters: [role])
    private_submission = create_submission.call('Anchor Private', :completed, other_template)
    private_submission.submitters.first.update!(email: target.submitters.first.email)
    SearchEntries.reindex_record(private_submission) if Docuseal.fulltext_search?
    literal_email = create_submission.call('Literal Email Reviewer')
    literal_email.submitters.first.update!(email: '123+practice_100%case@example.test')
    wildcard_email = create_submission.call('Wildcard Lookalike Reviewer')
    wildcard_email.submitters.first.update!(email: '123+practiceX100Ycase@example.test')
    [literal_email, wildcard_email].each { |record| SearchEntries.reindex_record(record) } if Docuseal.fulltext_search?
    browser.get('/submissions', headers:)
    check.call(rows.call.exclude?("submission_#{target.id}"), 'target begins beyond the first page')
    browser.get('/submissions', params: { q: 'Anchor', status: 'completed', author: user.email,
                                          completed_at_from: Date.yesterday.iso8601 }, headers:)
    check.call(rows.call == ["submission_#{target.id}"],
               'search combines with status/date/author and account authorization')
    email_queries = { full: target.submitters.first.email, uppercase: target.submitters.first.email.upcase,
                      partial: target.submitters.first.email[3..] }
    email_queries.each do |variant, email_query|
      browser.get('/submissions', params: { q: email_query, status: 'completed' }, headers:)
      check.call(rows.call == ["submission_#{target.id}"],
                 "#{variant} recipient email search finds an older authorized submission")
    end
    ['123+practice_100%case@example.test', 'practice_100%case@example.test'].each do |email_query|
      browser.get('/submissions', params: { q: email_query, status: 'completed' }, headers:)
      check.call(rows.call == ["submission_#{literal_email.id}"], 'email punctuation is matched literally')
    end
    browser.get('/submissions', params: { q: template.name }, headers:)
    check.call(rows.call.present?, 'global submissions search matches template names')
    browser.get('/submissions/archived', params: { q: 'Anchor' }, headers:)
    check.call(rows.call == ["submission_#{archived.id}"], 'archived search stays within archived records')
    browser.get("/templates/#{template.id}", params: { q: 'Anchor', status: 'completed' }, headers:)
    check.call(rows.call == ["submission_#{target.id}"], 'template search and status work together')
    browser.get('/submissions', params: { q: 'no-match-synthetic' }, headers:)
    page = Nokogiri::HTML(browser.response.body)
    check.call(rows.call.empty? && page.at_css('.bennett-submission-search').present?, 'empty search keeps controls')

    browser.get('/submissions', params: { q: 'Filler', status: 'completed', author: user.email, page: 2 }, headers:)
    page = Nokogiri::HTML(browser.response.body)
    clear = URI(page.at_css('[aria-label="Clear submission search"]')['href'])
    pending = URI(page.at_css('a.bennett-status-tab[href*="status=pending"]')['href'])
    check.call(Rack::Utils.parse_nested_query(clear.query).slice('status', 'author') ==
               { 'status' => 'completed', 'author' => user.email }, 'clearing search retains active filters')
    check.call(!Rack::Utils.parse_nested_query(clear.query).key?('page') &&
               !Rack::Utils.parse_nested_query(pending.query).key?('page'), 'search/status changes reset pagination')
    check.call(Rack::Utils.parse_nested_query(pending.query)['q'] == 'Filler', 'status change retains search')
    raise ActiveRecord::Rollback
  end

  begin
    browser.delete('/sign_out', headers:)
    check.call(browser.response.status == 422, 'CSRF refusal')
  rescue ActionController::InvalidAuthenticityToken
    checks += 1
  end
  browser.get('/submissions', headers:)
  check.call(browser.response.status == 200, 'session survives refused write')
  browser.delete('/sign_out', params: { authenticity_token: csrf.call(browser) }, headers:)
  check.call(redirects_to.call(browser, '/cdn-cgi/access/logout'), 'full Access logout')

  browser.get('/submissions')
  check.call(browser.response.status == 403, 'cookie cannot replace an assertion')
  check.call(browser.response.body.include?('We couldn’t sign you in'), 'helpful denied page')
  [{ aud: ['wrong-application'] }, { exp: Time.now.to_i - 60 }, { type: 'org' }, { email: nil }].each do |changes|
    browser.get('/submissions', headers: { 'Cf-Access-Jwt-Assertion' => make_token.call(user.email, changes) })
    check.call(browser.response.status == 403, 'invalid assertion rejected')
  end
  browser.get('/submissions', headers: { 'Cf-Access-Authenticated-User-Email' => user.email })
  check.call(browser.response.status == 403, 'email header is not identity')
  browser.get('/submissions', headers: { 'Cf-Access-Jwt-Assertion' => make_token.call('unknown@example.test') })
  check.call(browser.response.redirect? && browser.response.location == 'https://jud.bennettlegal.com/retainers',
             'staff viewers continue through JUD authorization')
  check.call(User.count == original_count, 'no automatic native account provisioning')

  browser.get('/submissions', headers:)
  user.update!(archived_at: Time.current)
  browser.get('/submissions', headers:)
  check.call(browser.response.status == 403, 'inactive user revokes an existing session')
  user.update!(archived_at: nil)
  public_browser = new_browser.call('sign.ci.test')
  public_browser.get('/submissions', headers:)
  check.call(redirects_to.call(public_browser, '/sign_in'), 'public host cannot use staff SSO')

  password = SecureRandom.hex(32)
  mfa_user = user.account.users.create!(first_name: 'Synthetic', last_name: 'MFA', email: 'mfa@example.test',
                                        password:, otp_secret: User.generate_otp_secret, otp_required_for_login: true)
  mfa_headers = { 'Cf-Access-Jwt-Assertion' => make_token.call(mfa_user.email) }
  mfa_browser = new_browser.call
  mfa_browser.get('/sign_in', headers: mfa_headers)
  check.call(mfa_browser.response.status == 200 && mfa_browser.response.body.include?('name="user[password]"'),
             'configured native MFA is preserved')
  mfa_browser.post('/sign_in', params: { authenticity_token: csrf.call(mfa_browser),
                                         user: { email: mfa_user.email, password: } }, headers: mfa_headers)
  check.call(mfa_browser.response.status == 422, 'native MFA challenge still required')
  mfa_browser.get('/submissions', headers: mfa_headers)
  check.call(mfa_browser.response.redirect?, 'no session before authenticator verification')
  mfa_browser.get('/sign_in', headers: mfa_headers)
  mfa_browser.post('/sign_in', params: { authenticity_token: csrf.call(mfa_browser),
                                         user: { email: mfa_user.email, password:,
                                                 otp_attempt: mfa_user.current_otp } }, headers: mfa_headers)
  check.call(redirects_to.call(mfa_browser, '/submissions'), 'authenticator login succeeds')
  mfa_browser.get('/submissions', headers: mfa_headers)
  check.call(mfa_browser.response.status == 200, 'authenticated MFA session')

  # A different/unselected host keeps Devise's normal password and existing-session guards.
  legacy_user = user.account.users.create!(first_name: 'Synthetic', last_name: 'Legacy',
                                           email: 'legacy@example.test', password:)
  legacy_browser = new_browser.call('sign.ci.test')
  legacy_browser.get('/sign_in')
  check.call(legacy_browser.response.status == 200, 'legacy password form')
  legacy_browser.post('/sign_in', params: { authenticity_token: csrf.call(legacy_browser),
                                            user: { email: legacy_user.email, password: } })
  check.call(legacy_browser.response.redirect?, 'legacy password login')
  legacy_browser.get('/sign_in')
  check.call(redirects_to.call(legacy_browser, '/'), 'legacy already-authenticated guard')
  legacy_browser.get('/submissions')
  check.call(Nokogiri::HTML(legacy_browser.response.body).at_css('a[href="/templates/new"]').present?,
             'unselected native workspace keeps template creation')
  raise ActiveRecord::Rollback
end
check.call(User.count == original_count, 'synthetic mutations rolled back')
puts({ staff_access: 'passed', checks: }.to_json)
