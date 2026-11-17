# frozen_string_literal: true

class User < ApplicationRecord
  # Googleだけでログインする利用者はパスワードを持たない。has_secure_password の
  # 既定のバリデーションは作成時にパスワードを必須にしてしまうため切り、
  # 長さと確認だけを自前で置き直す。
  has_secure_password validations: false

  has_one :student, dependent: :restrict_with_error
  has_many :sessions, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP },
                    uniqueness: { case_sensitive: false }
  validates :password, confirmation: true, allow_blank: true
  # bcrypt は73バイト目以降を無視するため、黙って切り詰めずに弾く。
  validates :password, length: { maximum: ActiveModel::SecurePassword::MAX_PASSWORD_LENGTH_ALLOWED },
                       allow_blank: true
  validates :google_uid, uniqueness: true, allow_nil: true
  # どちらの手段も持たない行は、作ってもログインできないので作らせない。
  validate :must_have_credential

  # Googleから返ってきた本人情報で、対応する利用者を引き当てる。無ければ作る。
  # 突き合わせはまず google_uid。メールアドレスは本人が変更できるため、
  # 同一性の判断には使わない。ただし既にパスワードで登録している人が同じ
  # メールアドレスでGoogleを使った場合は、別アカウントを作らず同じ行に繋ぐ。
  def self.from_google!(uid:, email:)
    find_by(google_uid: uid) || find_or_initialize_by(email: email).tap do |user|
      user.google_uid = uid
      user.save!
    end
  end

  def google_linked?
    google_uid.present?
  end

  private

  def must_have_credential
    return if password_digest.present? || google_uid.present?

    errors.add(:base, :no_credential)
  end
end

