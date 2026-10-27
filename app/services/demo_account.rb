# frozen_string_literal: true

class DemoAccount
  class Unavailable < StandardError; end

  EMAIL = 'demo@graduation-checker.example.test'
  ADMISSION_YEAR = 2024
  DEPARTMENT = 'intelligent_informatics'

  # PUBLIC_DEMO=1 は、認証が入るまでの仮公開用。ローカル限定の制限を外し、固定のデモ学生を誰にでも見せる。
  # 実際の成績データを入れた環境では設定しない。
  def self.public_demo?
    ENV['PUBLIC_DEMO'] == '1'
  end

  def self.enabled?
    Rails.env.local? || public_demo?
  end

  def self.student
    raise Unavailable, 'ローカルデモは開発・テスト環境でのみ利用できます。' unless enabled?

    student = User.find_by(email: EMAIL)&.student
    return student if student&.admission_year == ADMISSION_YEAR

    raise Unavailable, 'デモデータが未設定です。開発環境で bin/rails db:seed を実行してください。'
  end
end

