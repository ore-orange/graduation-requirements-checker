# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  has_one :student, dependent: :restrict_with_error
  has_many :sessions, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP },
                    uniqueness: { case_sensitive: false }
end

