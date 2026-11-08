# frozen_string_literal: true

# Bennett Legal source invariants for this DocuSeal fork.
#
# launch.rb runs this before any service starts, and the fork's tests run it on
# every build. It checks the code that carries the Bennett changes, not file
# hashes, so a nightly upstream merge passes as long as those changes survive
# it. Attribution and licence files are checked too: they must never be lost in
# a merge (DocuSeal LICENSE_ADDITIONAL_TERMS, AGPL-3.0 section 7(b)).
require 'prism'

module BennettSourceCheck
  # Signer mutations that must enforce recipient order (patch of 2026-11-01).
  # Every Submitters::AuthorizedForForm.call in these files must pass
  # `with_order: true`, except the read-only methods listed in READ_ONLY.
  ORDERED = {
    'app/controllers/submit_form_controller.rb' => %i[update],
    'app/controllers/submit_form_upload_controller.rb' => %i[authorize_upload!],
    'app/controllers/submit_form_invite_controller.rb' => %i[can_invite?],
    'app/controllers/submit_form_decline_controller.rb' => %i[create],
    'app/controllers/submit_form_prefill_attachments_controller.rb' => %i[create]
  }.freeze
  READ_ONLY = { 'app/controllers/submit_form_controller.rb' => %i[completed] }.freeze
  # Upload routes refuse view-only recipients.
  VIEWER_GUARDS = {
    'app/controllers/submit_form_upload_controller.rb' => :can_upload?,
    'app/controllers/submit_form_prefill_attachments_controller.rb' => :can_upload?
  }.freeze
  # The prefill route reads the signer's verification cookie.
  COOKIES = %w[app/controllers/submit_form_prefill_attachments_controller.rb].freeze
  ATTRIBUTION = {
    'app/views/layouts/application.html.erb' => ["render 'shared/bennett_staff_footer'"],
    'app/views/layouts/plain.html.erb' => ["render 'shared/bennett_staff_footer'"],
    'app/views/shared/_bennett_staff_footer.html.erb' =>
      ["t('powered_by')", 'Docuseal::PRODUCT_URL', 'Docuseal.product_name', "render 'shared/logo'"],
    'app/views/shared/_bennett_signing_masthead.html.erb' =>
      ["t('powered_by')", 'Docuseal::PRODUCT_URL', 'Docuseal.product_name'],
    'app/views/start_form/_banner.html.erb' => ["render 'shared/bennett_signing_masthead'"],
    'app/views/submit_form/_banner.html.erb' => ["render 'shared/bennett_signing_masthead'"],
    'app/views/layouts/mailer.html.erb' => ["render partial: 'shared/mailer_attribution'"],
    'app/views/shared/_mailer_attribution.html.erb' =>
      ['sent_using_product_name_open_source_software_html', 'Docuseal::PRODUCT_EMAIL_URL', 'Docuseal.product_name']
  }.freeze
  STAFF_AUTH = {
    'app/controllers/application_controller.rb' => ['include BennettStaffAuthentication'],
    'app/controllers/concerns/bennett_staff_authentication.rb' =>
      ['prepend_before_action :authenticate_bennett_staff!', 'active_for_authentication?', 'otp_required_for_login?'],
    'app/controllers/sessions_controller.rb' => ['bennett_staff?', "'/cdn-cgi/access/logout'"],
    'lib/bennett/staff_access.rb' => ['JWT.decode', "algorithms: ['RS256']", 'verify_iss: true', 'verify_aud: true']
  }.freeze
  LICENSES = %w[LICENSE LICENSE_ADDITIONAL_TERMS].freeze
  AUTHORIZE = 'Submitters::AuthorizedForForm'

  Failure = Class.new(StandardError)

  module_function

  def verify!(root)
    ORDERED.each do |path, methods|
      tree = parse(root, path)
      methods.each do |name|
        raise Failure, "#{path}##{name}: no recipient-order check" if authorizations(find_def(tree, name, path)).empty?
      end
      each_def(tree) do |definition|
        next if READ_ONLY.fetch(path, []).include?(definition.name)

        authorizations(definition).each do |call|
          raise Failure, "#{path}##{definition.name}: authorization without with_order: true" unless ordered?(call)
        end
      end
    end
    VIEWER_GUARDS.each do |path, name|
      raise Failure, "#{path}##{name}: viewers are not refused" unless refuses_viewer?(find_def(parse(root, path),
                                                                                                name, path))
    end
    COOKIES.each do |path|
      raise Failure, "#{path}: verification cookie not readable" unless includes_cookies?(parse(root, path))
    end
    verify_tokens!(root, ATTRIBUTION, 'attribution')
    verify_tokens!(root, STAFF_AUTH, 'staff authentication')
    LICENSES.each { |path| raise Failure, "#{path} missing" if read(root, path).strip.empty? }
    true
  end

  def verify_tokens!(root, groups, label)
    groups.each do |path, needles|
      text = read(root, path)
      needles.each { |needle| raise Failure, "#{path}: #{label} missing (#{needle})" unless text.include?(needle) }
    end
  end

  def read(root, path)
    target = File.join(root, path)
    raise Failure, "#{path} missing or linked" unless File.file?(target) && !File.symlink?(target)

    File.read(target)
  end

  def parse(root, path)
    result = Prism.parse(read(root, path))
    raise Failure, "#{path}: does not parse" unless result.errors.empty?

    result.value
  end

  def each_node(node, &)
    return unless node

    yield node
    node.compact_child_nodes.each { |child| each_node(child, &) }
  end

  def each_def(tree)
    each_node(tree) { |node| yield node if node.is_a?(Prism::DefNode) }
  end

  def find_def(tree, name, path)
    each_def(tree) { |definition| return definition if definition.name == name }
    raise Failure, "#{path}##{name} missing"
  end

  def calls(node, name)
    found = []
    each_node(node) { |child| found << child if child.is_a?(Prism::CallNode) && child.name == name }
    found
  end

  def authorizations(definition)
    calls(definition, :call).select { |call| call.receiver&.slice == AUTHORIZE }
  end

  def ordered?(call)
    (call.arguments&.arguments || []).any? do |argument|
      argument.is_a?(Prism::KeywordHashNode) && argument.elements.any? do |pair|
        pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) && pair.key.unescaped == 'with_order' &&
          pair.value.is_a?(Prism::TrueNode)
      end
    end
  end

  def refuses_viewer?(definition)
    calls(definition, :!).any? { |negation| negation.receiver.is_a?(Prism::CallNode) && negation.receiver.name == :viewer? }
  end

  def includes_cookies?(tree)
    calls(tree, :include).any? { |call| call.arguments&.arguments&.any? { |arg| arg.slice == 'ActionController::Cookies' } }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    BennettSourceCheck.verify!(ARGV.fetch(0))
    puts 'Bennett source check passed'
  rescue StandardError => e
    warn "Bennett source check failed: #{e.message}"
    exit 78
  end
end
