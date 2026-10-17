# frozen_string_literal: true

class DemoAccount
  class Unavailable < StandardError; end

  EMAIL = 'demo@graduation-checker.example.test'
  ADMISSION_YEAR = 2024
  DEPARTMENT = 'intelligent_informatics'

  def self.enabled?
    Rails.env.local?
  end

  def self.student
    raise Unavailable, 'ローカルデモは開発・テスト環境でのみ利用できます。' unless enabled?

    student = User.find_by(email: EMAIL)&.student
    return student if student&.admission_year == ADMISSION_YEAR

    raise Unavailable, 'デモデータが未設定です。開発環境で bin/rails db:seed を実行してください。'
  end
end

