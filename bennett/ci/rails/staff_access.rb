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
# rubocop:disable-next Metrics/BlockLength
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
  check.call(browser.response.status == 403 && User.count == original_count, 'no automatic account provisioning')

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
  raise ActiveRecord::Rollback
end
check.call(User.count == original_count, 'synthetic mutations rolled back')
puts({ staff_access: 'passed', checks: }.to_json)
