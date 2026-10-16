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
if Rails.env.production? && !ENV['SECRET_KEY_BASE_DUMMY']
  required_urls = %w[DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL]
  unless required_urls.all? { |name| ENV[name].present? }
    raise 'Production requires DATABASE_URL and separate CACHE/QUEUE/CABLE_DATABASE_URL settings. Shared DB consolidation is pending approval.'
  end

  ActiveRecord::Base.configurations.configs_for(env_name: 'production').each do |config|
    next if %w[require verify-ca verify-full].include?(config.configuration_hash[:sslmode])

    raise 'Production PostgreSQL connections must require SSL.'
  end

  targets = ActiveRecord::Base.configurations.configs_for(env_name: 'production').map do |config|
    settings = config.configuration_hash
    [settings[:host], settings.fetch(:port, 5432), settings[:database]]
  end
  unless targets.uniq.size == targets.size
    raise 'Shared production databases require an approved Solid Cache/Queue/Cable consolidation first.'
  end
end
