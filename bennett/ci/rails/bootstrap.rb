# frozen_string_literal: true

# CI copy of the production one-time setup (bennett-legal-ops
# deploy/docuseal/host/bootstrap.rb), equivalent to DocuSeal's /setup form: the
# account, its first admin, the signing URL, the PDF-signing certificate and
# the API token JUD uses. The smoke test feeds it synthetic values through
# DOCUSEAL_BOOTSTRAP_JSON; it prints counts and booleans only.
#
#   docker exec -i -w /app -e DOCUSEAL_BOOTSTRAP_JSON <docuseal> bin/rails runner - < bootstrap.rb
require 'json'

values = JSON.parse(ENV.fetch('DOCUSEAL_BOOTSTRAP_JSON'))
token = values.fetch('api_token')

if User.exists?
  puts({ setup: 'already done', users: User.count }.to_json)
  exit 0
end

ActiveRecord::Base.transaction do
  account = Account.new(name: values.fetch('account_name'), locale: 'en-US',
                        timezone: Accounts.normalize_timezone(values.fetch('timezone')))
  user = account.users.new(first_name: values.fetch('first_name'), last_name: values.fetch('last_name'),
                           email: values.fetch('email'), password: values.fetch('password'), role: User::ADMIN_ROLE)
  user.save!
  account.encrypted_configs.create!([
                                      { key: EncryptedConfig::APP_URL_KEY, value: values.fetch('app_url') },
                                      { key: EncryptedConfig::ESIGN_CERTS_KEY, value: GenerateCertificate.call.transform_values(&:to_pem) }
                                    ])
  account.account_configs.create!(key: :fulltext_search, value: true) if SearchEntry.table_exists?
  user.access_tokens.create!(token:)
end
Docuseal.refresh_default_url_options!

puts({ setup: 'done', accounts: Account.count, users: User.count,
       signing_certificate: EncryptedConfig.exists?(key: EncryptedConfig::ESIGN_CERTS_KEY),
       api_token: AccessToken.exists?(sha256: Digest::SHA256.hexdigest(token)) }.to_json)
