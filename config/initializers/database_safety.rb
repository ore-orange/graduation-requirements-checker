# frozen_string_literal: true

# DATABASE_URLの誤設定で、テスト準備が本番データを破壊することを防ぐ。
# Dockerのdbサービス、ホストのローカルPostgreSQL以外は開発・テストで許可しない。
if Rails.env.development? || Rails.env.test?
  local_hosts = %w[db localhost 127.0.0.1 ::1]

  # db:prepare等はdevelopmentからtest DBも扱うため、両方を検査する。
  { 'development' => 'grc_development', 'test' => 'grc_test' }.each do |environment, expected_database|
    ActiveRecord::Base.configurations.configs_for(env_name: environment).each do |config|
      settings = config.configuration_hash
      next if local_hosts.include?(settings[:host]) && settings[:database] == expected_database

      raise 'Unsafe development/test database configuration. Use local PostgreSQL and the environment-specific grc database.'
    end
  end
end

# 本番のローカルDBへのフォールバックを禁止する。アセットのビルド時だけ接続不要。
# 本番は単一DB（primary）。Solid Cache/Queue/Cableは使わない設定にしている。
if Rails.env.production? && !ENV['SECRET_KEY_BASE_DUMMY']
  raise 'Production requires DATABASE_URL.' unless ENV['DATABASE_URL'].present?

  ActiveRecord::Base.configurations.configs_for(env_name: 'production').each do |config|
    next if %w[require verify-ca verify-full].include?(config.configuration_hash[:sslmode])

    raise 'Production PostgreSQL connections must require SSL.'
  end
end
