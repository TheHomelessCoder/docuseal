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

  def test_licences_are_the_upstream_bytes
    LICENSES.each { |file, sha| assert_equal sha, Digest::SHA256.file(BennettTest.path(file)).hexdigest, file }
  end
end
