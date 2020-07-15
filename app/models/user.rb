# frozen_string_literal: true
# == Schema Information
#
# Table name: users
#
#  id                        :bigint(8)        not null, primary key
#  email                     :string           default(""), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  encrypted_password        :string           default(""), not null
#  reset_password_token      :string
#  reset_password_sent_at    :datetime
#  remember_created_at       :datetime
#  sign_in_count             :integer          default(0), not null
#  current_sign_in_at        :datetime
#  last_sign_in_at           :datetime
#  current_sign_in_ip        :inet
#  last_sign_in_ip           :inet
#  admin                     :boolean          default(FALSE), not null
#  confirmation_token        :string
#  confirmed_at              :datetime
#  confirmation_sent_at      :datetime
#  unconfirmed_email         :string
#  locale                    :string
#  encrypted_otp_secret      :string
#  encrypted_otp_secret_iv   :string
#  encrypted_otp_secret_salt :string
#  consumed_timestep         :integer
#  otp_required_for_login    :boolean          default(FALSE), not null
#  last_emailed_at           :datetime
#  otp_backup_codes          :string           is an Array
#  filtered_languages        :string           default([]), not null, is an Array
#  account_id                :bigint(8)        not null
#  disabled                  :boolean          default(FALSE), not null
#  moderator                 :boolean          default(FALSE), not null
#  invite_id                 :bigint(8)
#  remember_token            :string
#  chosen_languages          :string           is an Array
#  created_by_application_id :bigint(8)
#  approved                  :boolean          default(TRUE), not null
#

class User < ApplicationRecord
  include Settings::Extend
  include UserRoles

  # The home and list feeds will be stored in Redis for this amount
  # of time, and status fan-out to followers will include only people
  # within this time frame. Lowering the duration may improve performance
  # if lots of people sign up, but not a lot of them check their feed
  # every day. Raising the duration reduces the amount of expensive
  # RegenerationWorker jobs that need to be run when those people come
  # to check their feed
  ACTIVE_DURATION = ENV.fetch('USER_ACTIVE_DAYS', 7).to_i.days.freeze

  devise :two_factor_authenticatable,
         otp_secret_encryption_key: Rails.configuration.x.otp_secret

  devise :two_factor_backupable,
         otp_number_of_backup_codes: 10

  devise :registerable, :recoverable, :rememberable, :trackable, :validatable,
         :confirmable

  include Omniauthable
  include PamAuthenticable
  include LdapAuthenticable

  belongs_to :account, inverse_of: :user
  belongs_to :invite, counter_cache: :uses, optional: true
  belongs_to :created_by_application, class_name: 'Doorkeeper::Application', optional: true
  accepts_nested_attributes_for :account

  has_many :applications, class_name: 'Doorkeeper::Application', as: :owner
  has_many :backups, inverse_of: :user
  has_many :invites, inverse_of: :user
  has_many :markers, inverse_of: :user, dependent: :destroy

  has_one :invite_request, class_name: 'UserInviteRequest', inverse_of: :user, dependent: :destroy
  accepts_nested_attributes_for :invite_request, reject_if: :allow_empty_invite_request?

  validates :locale, inclusion: I18n.available_locales.map(&:to_s), if: :locale?
  validates_with BlacklistedEmailValidator, on: :create
  validates_with EmailMxValidator, if: :validate_email_dns?
  validates :agreement, acceptance: { allow_nil: false, accept: [true, 'true', '1'] }, on: :create

  scope :recent, -> { order(id: :desc) }
  scope :pending, -> { where(approved: false) }
  scope :approved, -> { where(approved: true) }
  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :enabled, -> { where(disabled: false) }
  scope :disabled, -> { where(disabled: true) }
  scope :inactive, -> { where(arel_table[:current_sign_in_at].lt(ACTIVE_DURATION.ago)) }
  scope :active, -> { confirmed.where(arel_table[:current_sign_in_at].gteq(ACTIVE_DURATION.ago)).joins(:account).where(accounts: { suspended_at: nil }) }
  scope :matches_email, ->(value) { where(arel_table[:email].matches("#{value}%")) }
  scope :matches_ip, ->(value) { left_joins(:session_activations).where('users.current_sign_in_ip <<= ?', value).or(left_joins(:session_activations).where('users.last_sign_in_ip <<= ?', value)).or(left_joins(:session_activations).where('session_activations.ip <<= ?', value)) }
  scope :emailable, -> { confirmed.enabled.joins(:account).merge(Account.searchable) }

  before_validation :sanitize_languages
  before_create :set_approved
  after_commit :send_pending_devise_notifications

  # This avoids a deprecation warning from Rails 5.1
  # It seems possible that a future release of devise-two-factor will
  # handle this itself, and this can be removed from our User class.
  attribute :otp_secret

  has_many :session_activations, dependent: :destroy

  delegate :auto_play_gif, :default_sensitive, :unfollow_modal, :boost_modal, :delete_modal, :emoji_size_simple, :emoji_size_detailed, :emoji_size_name,
           :bbcode_spin, :bbcode_pulse, :bbcode_b, :bbcode_i, :bbcode_color, :bbcode_s, :bbcode_large, :bbcode_size, :bbcode_u, :bbcode_flip, :show_cw_box,
           :reduce_motion, :system_font_ui, :noindex, :theme, :display_media, :hide_network,
           :expand_spoilers, :default_language, :aggregate_reblogs, :show_application,
           :advanced_layout, :use_blurhash, :use_pending_items, :trends, :crop_images,
           to: :settings, prefix: :setting, allow_nil: false

  attr_reader :invite_code
  attr_writer :external

  def confirmed?
    confirmed_at.present?
  end

  def invited?
    invite_id.present?
  end

  def valid_invitation?
    invite_id.present? && invite.valid_for_use?
  end

  def disable!
    update!(disabled: true)
  end

  def enable!
    update!(disabled: false)
  end

  def confirm
    new_user      = !confirmed?
    self.approved = true if open_registrations?

    super

    if new_user && approved?
      prepare_new_user!
    elsif new_user
      notify_staff_about_pending_account!
    end
  end

  def confirm!
    new_user      = !confirmed?
    self.approved = true if open_registrations?

    skip_confirmation!
    save!

    prepare_new_user! if new_user && approved?
  end

  def pending?
    !approved?
  end

  def active_for_authentication?
    true
  end

  def functional?
    confirmed? && approved? && !disabled? && !account.suspended? && account.moved_to_account_id.nil?
  end

  def unconfirmed_or_pending?
    !(confirmed? && approved?)
  end

  def inactive_message
    !approved? ? :pending : super
  end

  def approve!
    return if approved?

    update!(approved: true)
    prepare_new_user!
  end

  def update_tracked_fields!(request)
    super
    prepare_returning_user!
  end

  def disable_two_factor!
    self.otp_required_for_login = false
    otp_backup_codes&.clear
    save!
  end

  def setting_default_privacy
    settings.default_privacy || (account.locked? ? 'private' : 'public')
  end

  def allows_digest_emails?
    settings.notification_emails['digest']
  end

  def allows_report_emails?
    settings.notification_emails['report']
  end

  def allows_pending_account_emails?
    settings.notification_emails['pending_account']
  end

  def allows_trending_tag_emails?
    settings.notification_emails['trending_tag']
  end

  def hides_network?
    @hides_network ||= settings.hide_network
  end

  def aggregates_reblogs?
    @aggregates_reblogs ||= settings.aggregate_reblogs
  end

  def shows_application?
    @shows_application ||= settings.show_application
  end

  def token_for_app(a)
    return nil if a.nil? || a.owner != self
    Doorkeeper::AccessToken
      .find_or_create_by(application_id: a.id, resource_owner_id: id) do |t|

      t.scopes = a.scopes
      t.expires_in = Doorkeeper.configuration.access_token_expires_in
      t.use_refresh_token = Doorkeeper.configuration.refresh_token_enabled?
    end
  end

  def activate_session(request)
    session_activations.activate(session_id: SecureRandom.hex,
                                 user_agent: request.user_agent,
                                 ip: request.remote_ip).session_id
  end

  def clear_other_sessions(id)
    session_activations.exclusive(id)
  end

  def session_active?(id)
    session_activations.active? id
  end

  def web_push_subscription(session)
    session.web_push_subscription.nil? ? nil : session.web_push_subscription
  end

  def invite_code=(code)
    self.invite  = Invite.find_by(code: code) if code.present?
    @invite_code = code
  end

  def password_required?
    return false if external?

    super
  end

  def send_reset_password_instructions
    return false if encrypted_password.blank?

    super
  end

  def reset_password!(new_password, new_password_confirmation)
    return false if encrypted_password.blank?

    super
  end

  def show_all_media?
    setting_display_media == 'show_all'
  end

  def hide_all_media?
    setting_display_media == 'hide_all'
  end

  def recent_ips
    @recent_ips ||= begin
      arr = []

      session_activations.each do |session_activation|
        arr << [session_activation.updated_at, session_activation.ip]
      end

      arr << [current_sign_in_at, current_sign_in_ip] if current_sign_in_ip.present?
      arr << [last_sign_in_at, last_sign_in_ip] if last_sign_in_ip.present?

      arr.sort_by { |pair| pair.first || Time.now.utc }.uniq(&:last).reverse!
    end
  end

  protected

  def send_devise_notification(notification, *args)
    # This method can be called in `after_update` and `after_commit` hooks,
    # but we must make sure the mailer is actually called *after* commit,
    # otherwise it may work on stale data. To do this, figure out if we are
    # within a transaction.
    if ActiveRecord::Base.connection.current_transaction.try(:records)&.include?(self)
      pending_devise_notifications << [notification, args]
    else
      render_and_send_devise_message(notification, *args)
    end
  end

  private

  def send_pending_devise_notifications
    pending_devise_notifications.each do |notification, args|
      render_and_send_devise_message(notification, *args)
    end

    # Empty the pending notifications array because the
    # after_commit hook can be called multiple times which
    # could cause multiple emails to be sent.
    pending_devise_notifications.clear
  end

  def pending_devise_notifications
    @pending_devise_notifications ||= []
  end

  def render_and_send_devise_message(notification, *args)
    devise_mailer.send(notification, self, *args).deliver_later
  end

  def set_approved
    self.approved = open_registrations? || valid_invitation? || external?
  end

  def open_registrations?
    Setting.registrations_mode == 'open'
  end

  def approved_registrations?
    Setting.registrations_mode == 'approved'
  end

  def allow_empty_invite_request?(attributes)
    attributes['text'].blank? && (!approved_registrations? || invited?)
  end

  def external?
    !!@external
  end

  def sanitize_languages
    return if chosen_languages.nil?
    chosen_languages.reject!(&:blank?)
    self.chosen_languages = nil if chosen_languages.empty?
  end

  def prepare_new_user!
    BootstrapTimelineWorker.perform_async(account_id)
    ActivityTracker.increment('activity:accounts:local')
    UserMailer.welcome(self).deliver_later
  end

  def prepare_returning_user!
    ActivityTracker.record('activity:logins', id)
    regenerate_feed! if needs_feed_update?
  end

  def notify_staff_about_pending_account!
    return if invite_request.text =~ /http/i
    User.staff.includes(:account).each do |u|
      next unless u.allows_pending_account_emails?
      AdminMailer.new_pending_account(u.account, self).deliver_later
    end
  end

  def regenerate_feed!
    return unless Redis.current.setnx("account:#{account_id}:regeneration", true)
    Redis.current.expire("account:#{account_id}:regeneration", 1.day.seconds)
    RegenerationWorker.perform_async(account_id)
  end

  def needs_feed_update?
    last_sign_in_at < ACTIVE_DURATION.ago
  end

  def validate_email_dns?
    email_changed? && !(Rails.env.test? || Rails.env.development?)
  end
end
