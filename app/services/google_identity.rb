# frozen_string_literal: true

# Googleから返ってきた本人情報のうち、ログインの可否に関わる部分だけを扱う。
# OmniAuthのAuthHashをそのままコントローラで触ると、判定がどこにあるか追えなくなるため挟む。
class GoogleIdentity
  # 既定は知能情報コースの学生が使うドメイン。他学部へ広げるときはENVで足す。
  DEFAULT_DOMAINS = %w[ie.u-ryukyu.ac.jp].freeze

  def self.allowed_domains
    ENV.fetch('ALLOWED_EMAIL_DOMAINS', nil)&.split(',')&.map { |domain| domain.strip.downcase }.presence ||
      DEFAULT_DOMAINS
  end

  def self.from(auth)
    info = auth.info
    new(uid: auth.uid, email: info.email, email_verified: info.email_verified)
  end

  attr_reader :uid, :email

  def initialize(uid:, email:, email_verified:)
    @uid = uid
    @email = email.to_s.strip.downcase
    @email_verified = email_verified
  end

  # Googleがメールアドレスの所有を確認済みであること。
  # 文字列の "true" で返ることがあるため、真偽値に寄せずに比較する。
  def email_verified?
    @email_verified.to_s == 'true'
  end

  # 学内のアカウントであること。hdパラメータは利用者側から渡せるため見ない。
  # 確認済みのメールアドレスのドメインだけを根拠にする。
  def allowed_domain?
    return false unless email_verified?

    self.class.allowed_domains.include?(email.split('@').last)
  end
end

