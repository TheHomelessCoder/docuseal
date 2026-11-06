# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: 'DocuSeal <info@docuseal.com>'
  layout 'mailer'

  register_interceptor ActionMailerConfigsInterceptor
  register_interceptor HtmlToPlainTextInterceptor
  register_preview_interceptor HtmlToPlainTextInterceptor

  register_observer ActionMailerEventsObserver

  before_action do
    ActiveStorage::Current.url_options = Docuseal.default_url_options
  end

  # Carry the letterhead with the message. Mail clients can block or proxy remote
  # images independently of the signing service; no HTTP request is needed here.
  before_action :attach_bennett_brand_images

  after_action :set_message_metadata
  after_action :set_message_uuid

  def default_url_options
    Docuseal.default_url_options.merge(host: ENV.fetch('EMAIL_HOST', Docuseal.default_url_options[:host]))
  end

  def set_message_metadata
    message.instance_variable_set(:@message_metadata, @message_metadata || {})
  end

  def set_message_uuid
    message['X-Message-Uuid'] = SecureRandom.uuid
  end

  def assign_message_metadata(tag, record)
    @message_metadata = (@message_metadata || {}).merge(
      'tag' => tag,
      'record_id' => record.id,
      'record_type' => record.class.name
    )
  end

  def put_metadata(attrs)
    @message_metadata = (@message_metadata || {}).merge(attrs)
  end

  private

  def attach_bennett_brand_images
    %w[footer-logo linkedin-gold instagram-gold facebook-gold youtube-gold].each do |name|
      filename = "bennett-mail-#{name}.png"
      attachments.inline[filename] = {
        mime_type: 'image/png',
        content: File.binread(Rails.root.join('public', 'packs', filename))
      }
    end
  end
end
