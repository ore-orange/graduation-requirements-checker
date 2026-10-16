# frozen_string_literal: true

# bin/rails runner script/database_target.rb
# URL・パスワードを表示しない、接続先の読み取り専用チェック。
puts "Rails environment: #{Rails.env}"
ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |config|
  settings = config.configuration_hash
  puts "#{config.name}: host=#{settings[:host]} port=#{settings.fetch(:port, 5432)}"
  puts "  database=#{settings[:database]} sslmode=#{settings[:sslmode]}"
end

result = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
  SELECT current_database() AS database,
         inet_server_addr()::text AS server,
         (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) AS ssl
SQL
puts "Primary connection: database=#{result['database']} server=#{result['server']} ssl=#{result['ssl']}"

