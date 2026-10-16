# frozen_string_literal: true

require 'test_helper'

class DatabaseConfigurationTest < ActiveSupport::TestCase
  test 'production connection URLs and SSL are resolved without connecting' do
    with_production_settings do
      configurations = ActiveRecord::DatabaseConfigurations.new(Rails.application.config.database_configuration)
      primary = configurations.configs_for(env_name: 'production', name: 'primary').configuration_hash
      assert_equal 'production.example.invalid', primary[:host]
      assert_equal 'production_primary', primary[:database]
      assert_equal 'require', primary[:sslmode]
      assert_equal 4, configurations.configs_for(env_name: 'production').size
      assert_equal 'production_cache', configurations.configs_for(env_name: 'production', name: 'cache').database
    end
  end

  test 'certificate verification and certificate path are configurable' do
    with_production_settings do
      ENV['DATABASE_SSLMODE'] = 'verify-full'
      ENV['DATABASE_SSLROOTCERT'] = '/test-only/root.crt'
      configurations = ActiveRecord::DatabaseConfigurations.new(Rails.application.config.database_configuration)
      primary = configurations.configs_for(env_name: 'production', name: 'primary').configuration_hash
      assert_equal 'verify-full', primary[:sslmode]
      assert_equal '/test-only/root.crt', primary[:sslrootcert]
    end
  end

  test 'student grades and credit details are filtered from request parameters' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('grade' => 'test-grade', 'credits_earned' => 2,
                             'student_courses' => [{ 'course_id' => 1 }], 'database_url' => 'test-only')
    assert_equal ['[FILTERED]'], filtered.values.uniq
  end

  private

  def with_production_settings
    settings = {
      'DATABASE_URL' => 'postgresql://production.example.invalid/production_primary',
      'CACHE_DATABASE_URL' => 'postgresql://production.example.invalid/production_cache',
      'QUEUE_DATABASE_URL' => 'postgresql://production.example.invalid/production_queue',
      'CABLE_DATABASE_URL' => 'postgresql://production.example.invalid/production_cable',
      'DATABASE_SSLMODE' => 'require', 'DATABASE_SSLROOTCERT' => nil
    }
    original = ENV.to_h.slice(*settings.keys)
    settings.each { |name, value| ENV[name] = value }
    yield
  ensure
    settings.each_key { |name| ENV[name] = original[name] }
  end
end

