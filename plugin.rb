# name: discourse-onesignal
# about: Push notifications via the OneSignal API.
# version: 2.0
# authors: pmusaraj
# url: https://github.com/pmusaraj/discourse-onesignal

enabled_site_setting :onesignal_push_enabled

register_asset 'stylesheets/common/app-login.scss'
register_asset 'stylesheets/mobile/app-login.scss', :mobile

load File.expand_path('lib/discourse-onesignal/engine.rb', __dir__)

after_initialize do
  ONESIGNALAPI = 'https://onesignal.com/api/v1/notifications'

  User.class_eval do
    has_many :onesignal_subscriptions, dependent: :delete_all
  end


  PostAlerter.class_eval do
    def self.push_notification(user, payload)
      return if user.do_not_disturb?

      DiscoursePluginRegistry.push_notification_filters.each do |filter|
        return unless filter.call(user, payload)
      end

      if SiteSetting.onesignal_app_id.nil? || SiteSetting.onesignal_app_id.empty?
        Rails.logger.warn('OneSignal App ID is missing')
      end
      if SiteSetting.onesignal_rest_api_key.nil? || SiteSetting.onesignal_rest_api_key.empty?
        Rails.logger.warn('OneSignal REST API Key is missing')
      end

      if user.push_subscriptions.exists?
        Jobs.enqueue(:send_push_notification, user_id: user.id, payload: payload)
      end

      if user.onesignal_subscriptions.exists?
        Jobs.enqueue(:onesignal_pushnotification, payload: payload, username: user.username)
      end

      if SiteSetting.allow_user_api_key_scopes.split("|").include?("push") && SiteSetting.allowed_user_api_push_urls.present?
        clients = user.user_api_keys
          .joins(:scopes)
          .where("user_api_key_scopes.name IN ('push', 'notifications')")
          .where("push_url IS NOT NULL AND push_url <> ''")
          .where("position(push_url IN ?) > 0", SiteSetting.allowed_user_api_push_urls)
          .where("revoked_at IS NULL")
          .order(client_id: :asc)
          .pluck(:client_id, :push_url)

        if clients.length > 0
          Jobs.enqueue(:push_notification, clients: clients, payload: payload, user_id: user.id)
        end
      end
    end
  end

  # DiscourseEvent.on(:post_notification_alert) do |user, payload|

  #   if SiteSetting.onesignal_app_id.nil? || SiteSetting.onesignal_app_id.empty?
  #     Rails.logger.warn('OneSignal App ID is missing')
  #   end
  #   if SiteSetting.onesignal_rest_api_key.nil? || SiteSetting.onesignal_rest_api_key.empty?
  #     Rails.logger.warn('OneSignal REST API Key is missing')
  #   end

  #   # legacy, no longer used
  #   clients = user.user_api_keys
  #       .where("('push' = ANY(scopes) OR 'notifications' = ANY(scopes)) AND push_url IS NOT NULL AND position(push_url in ?) > 0 AND revoked_at IS NULL",
  #                 ONESIGNALAPI)
  #       .pluck(:client_id, :push_url)

  #   if user.onesignal_subscriptions.exists? || clients.length > 0
  #     Jobs.enqueue(:onesignal_pushnotification, payload: payload, username: user.username)
  #   end
  # end

  module ::Jobs
    class OnesignalPushnotification < ::Jobs::Base
      def execute(args)
        payload = args["payload"]

        heading = ""

        case payload[:notification_type]
        when Notification.types[:chat_mention]
          heading = I18n.t("notifications.titles.chat_mention")
        when Notification.types[:chat_message]
          heading = I18n.t("notifications.titles.chat_message")
        end

        if heading.blank?
          heading = payload[:topic_title].blank? ? "Notification" : payload[:topic_title]
        end

        params = {
          "app_id" => SiteSetting.onesignal_app_id,
          "contents" => {"en" => "#{payload[:username]}: #{payload[:excerpt]}"},
          "headings" => {"en" => heading},
          "data" => {"discourse_url" => payload[:post_url]},
          "ios_badgeType" => "Increase",
          "ios_badgeCount" => "1",
          "filters" => [
              {"field": "tag", "key": "username", "relation": "=", "value": args["username"]},
            ]
        }

        uri = URI.parse(ONESIGNALAPI)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path,
            'Content-Type'  => 'application/json;charset=utf-8',
            'Authorization' => "Basic #{SiteSetting.onesignal_rest_api_key}")
        request.body = params.as_json.to_json
        response = http.request(request)

        case response
        when Net::HTTPSuccess then
          Rails.logger.info("Push notification sent via OneSignal to #{args['username']}.")
        else
          Rails.logger.error("OneSignal error when sending a push notification")
          Rails.logger.error("#{request.to_yaml}")
          Rails.logger.error("#{response.to_yaml}")
        end

      end
    end
  end
end
