# frozen_string_literal: true

require_relative 'helper'

# Signer chrome and emails are normal source in this fork. These checks keep
# them shippable; bennett/test/branding_layout.test.cjs checks them in a browser.
class BrandingTest < Minitest::Test
  LAYOUT = BennettTest.read('app/views/layouts/form.html.erb')
  # Upstream licence bytes (DocuSeal 3.3.4 and 3.3.5). A change upstream needs review.
  LICENSES = {
    'LICENSE' => '76a97c878c9c7a8321bb395c2b44d3fe2f8d81314d219b20138ed0e2dddd5182',
    'LICENSE_ADDITIONAL_TERMS' => '67e378d842d69f209fc9f4061419b0f93025eea850142869c2399cb05c4d3565'
  }.freeze

  def test_masthead_shows_the_firm_logo_and_keeps_docuseal_attribution
    masthead = BennettTest.read('app/views/shared/_bennett_signing_masthead.html.erb')
    assert_includes masthead, 'alt="Bennett Legal"'
    assert_includes masthead, 'src="/packs/bennett-legal-logo-white.png"'
    %w[t('powered_by') Docuseal::PRODUCT_URL Docuseal.product_name].each { |needle| assert_includes masthead, needle }
    assert BennettSourceCheck.verify!(BennettTest::ROOT)
  end

  def test_signer_layout_loads_same_origin_assets_with_one_cache_version
    css = LAYOUT[%r{href="/packs/bennett-signing-v1\.css\?v=([0-9a-z]+)"}, 1]
    js = LAYOUT[%r{src="/packs/bennett-signing-v1\.js\?v=([0-9a-z]+)"}, 1]
    assert css, 'stylesheet missing from the signer layout'
    assert_equal css, js, 'bump the stylesheet and script version together'
    assert_includes LAYOUT, '<meta name="robots" content="noindex, nofollow">'
    assert_includes LAYOUT, '<body class="bennett-signer">'
    refute_match(%r{(?:src|href)="(?:https?:)?//}, LAYOUT, 'signer assets must stay same-origin under the CSP')
  end

  def test_every_referenced_asset_exists_and_fonts_carry_their_licences
    referenced = Dir[BennettTest.path('app/views/**/*.erb')].sum([]) { |file| File.read(file).scan(%r{/(?:packs|fonts)/bennett-[A-Za-z0-9._-]+}) }
    referenced += BennettTest.read('public/packs/bennett-signing-v1.css').scan(%r{/fonts/bennett-[A-Za-z0-9._-]+})
    assert_operator referenced.uniq.length, :>=, 8
    referenced.uniq.each { |asset| assert File.file?(BennettTest.path('public', asset)), asset }
    { 'bennett-jost-latin.woff2' => 'bennett-OFL-Jost.txt', 'bennett-noto-serif-latin.woff2' => 'bennett-OFL-NotoSerif.txt' }.each do |font, licence|
      assert_equal 'wOF2', File.binread(BennettTest.path('public/fonts', font), 4), font
      assert_includes BennettTest.read('public/fonts', licence), 'SIL OPEN FONT LICENSE'
    end
  end

  def test_build_context_and_git_keep_the_signer_assets
    lines = BennettTest.read('.dockerignore').lines.map(&:strip)
    exclude, include = lines.index('/public/packs/*'), lines.index('!/public/packs/bennett-*')
    assert exclude && include && exclude < include, '.dockerignore must keep public/packs/bennett-*'
    refute_includes lines, '/public/packs', '.dockerignore would drop the Bennett signer assets'
    %w[public/packs/bennett-signing-v1.css public/packs/bennett-signing-v1.js].each do |asset|
      assert_empty `git -C #{BennettTest::ROOT} check-ignore #{asset}`.strip, "#{asset} is git-ignored"
    end
  end

  def test_signer_script_writes_text_only
    script = BennettTest.read('public/packs/bennett-signing-v1.js')
    assert_includes script, 'textContent'
    refute_match(/innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function/, script)
  end

  MAILER = BennettTest.read('app/views/layouts/mailer.html.erb')
  # Partials whose text lands in every Bennett email.
  EMAIL_PARTS = %w[app/views/layouts/mailer.html.erb app/views/shared/_mailer_attribution.html.erb
                   app/views/submitter_mailer/_bennett_paragraph.html.erb app/views/submitter_mailer/_bennett_button.html.erb
                   app/views/submitter_mailer/_bennett_closing.html.erb].freeze

  # Emails use the intake nurture letterhead (bennett-legal-ops services/jud-dashboard/
  # lib/intake/nurture/design.ts), in light mode and in every dark mode it handles.
  def test_emails_use_the_nurture_letterhead
    ['<meta name="color-scheme" content="light dark">', '<meta name="supported-color-schemes" content="light dark">',
     ':root{color-scheme:light dark;supported-color-schemes:light dark}', 'u + .email-body .gmail-difference',
     'class="email-body email-page"', 'class="email-paper" bgcolor="#fcfaf5"', 'class="email-page" bgcolor="#f0f1f1"',
     'class="inset email-header navy-surface" bgcolor="#001a2d"', 'class="inset email-disclosure" bgcolor="#efefed"',
     'class="inset contact-footer navy-surface" bgcolor="#001a2d"', 'https://clients.bennettlegal.com/brand/nurture',
     'tel:+19729724969', 'mailto:solar@bennettlegal.com', "'RETAINER AGREEMENT'", "'CONTRATO DE SERVICIOS LEGALES'",
     "render partial: 'shared/mailer_attribution'"].each { |needle| assert MAILER.include?(needle), "letterhead lost #{needle}" }
    # Outlook recolours navy surfaces unless they carry a background image.
    assert_operator MAILER.scan('background-image:linear-gradient(#001a2d,#001a2d)').length, :>=, 3
    dark = MAILER[/@media \(prefers-color-scheme:dark\)\{(.*?)\}\}/, 1]
    %w[email-page email-paper email-text email-heading email-muted email-link email-callout email-disclosure email-rule
       cta-surface cta-link navy-surface video-kicker footer-address footer-link].each do |name|
      assert dark&.include?(".#{name}{"), "no prefers-color-scheme rule for .#{name}"
      assert MAILER.include?("[data-ogsc] .#{name},[data-ogsb] .#{name}{"), "no Outlook rule for .#{name}"
    end
    button = BennettTest.read('app/views/submitter_mailer/_bennett_button.html.erb')
    %w[cta-surface cta-link border:1px\ solid\ #b18b35 gmail-difference].each { |needle| assert button.include?(needle), "button lost #{needle}" }
    assert BennettTest.read('app/views/submitter_mailer/otp_verification_email.html.erb').include?('class="email-callout"'),
           'the code is no longer in the letterhead callout'
  end

  # The plain-text part is converted from the HTML (lib/html_to_plain_text.rb), and the
  # nightly smoke test reads the code as its first six-digit number. The stylesheet
  # (full of six-digit colours), the title and the hidden preview stay out of it.
  def test_email_text_part_leaves_out_the_stylesheet
    markers = %r{<!-- start text/html -->.*?<!-- end text/html -->}m
    assert_includes BennettTest.read('lib/html_to_plain_text.rb'), markers.source
    visible = MAILER.gsub(markers, '')
    assert MAILER.include?('<style>'), 'the letterhead has no stylesheet'
    refute visible.match?(/<style|<title|display:none/), 'the stylesheet, title or hidden preview would reach the plain-text part'
    EMAIL_PARTS.each do |file|
      text = BennettTest.read(file).gsub(markers, '').gsub(/<%.*?%>/m, '').gsub(/<[^>]*>/, ' ')
      refute_match(/\b\d{6}\b/, text, "#{file} prints a six-digit number")
    end
  end

  def test_licences_are_the_upstream_bytes
    LICENSES.each { |file, sha| assert_equal sha, Digest::SHA256.file(BennettTest.path(file)).hexdigest, file }
  end
end
