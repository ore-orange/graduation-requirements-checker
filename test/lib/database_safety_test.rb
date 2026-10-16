# frozen_string_literal: true

require 'test_helper'
require 'open3'

class DatabaseSafetyTest < ActiveSupport::TestCase
  test 'remote URL is blocked before a database connection can be made' do
    assert_blocked('DATABASE_URL' => 'postgres://example.invalid/postgres')
  end

  test 'local test URL cannot point to development database' do
    assert_blocked('TEST_DATABASE_URL' => 'postgres://localhost/grc_development')
  end

  test 'development boot also checks the test database used by db prepare' do
    assert_blocked('RAILS_ENV' => 'development', 'TEST_DATABASE_URL' => 'postgres://example.invalid/postgres')
  end

  test 'production never falls back to local databases without URL settings' do
    environment = production_environment.transform_values { nil }
    assert_boot_rejected(environment.merge('RAILS_ENV' => 'production', 'SECRET_KEY_BASE' => '0' * 128),
                         'Production requires DATABASE_URL')
  end

  test 'production rejects URLs that explicitly disable SSL' do
    environment = production_environment.merge(
      'DATABASE_URL' => 'postgres://production.example.invalid/production_primary?sslmode=disable'
    )
    assert_boot_rejected(environment, 'Production PostgreSQL connections must require SSL')
  end

  test 'production rejects shared URLs until Solid consolidation is approved' do
    environment = production_environment.merge(
      'CACHE_DATABASE_URL' => 'postgres://production.example.invalid/production_primary'
    )
    assert_boot_rejected(environment, 'Shared production databases require an approved')
  end

  private

  def production_environment
    {
      'RAILS_ENV' => 'production', 'SECRET_KEY_BASE' => '0' * 128, 'SECRET_KEY_BASE_DUMMY' => nil,
      'DATABASE_SSLMODE' => 'require', 'DATABASE_SSLROOTCERT' => nil,
      'DATABASE_URL' => 'postgres://production.example.invalid/production_primary',
      'CACHE_DATABASE_URL' => 'postgres://production.example.invalid/production_cache',
      'QUEUE_DATABASE_URL' => 'postgres://production.example.invalid/production_queue',
      'CABLE_DATABASE_URL' => 'postgres://production.example.invalid/production_cable'
    }
  end

  def assert_blocked(overrides)
    environment = { 'RAILS_ENV' => 'test', 'DATABASE_URL' => nil, 'TEST_DATABASE_URL' => nil }.merge(overrides)
    assert_boot_rejected(environment, 'Unsafe development/test database configuration')
  end

  def assert_boot_rejected(environment, expected_message)
    stdout, stderr, status = Open3.capture3(environment, 'bin/rails', 'runner', 'abort "Unexpected successful boot"',
                                            chdir: Rails.root)
    assert_not status.success?
    assert_includes stdout + stderr, expected_message
    assert_not_includes stdout + stderr, 'Unexpected successful boot'
    assert_not_includes stdout + stderr, 'postgres://'
  end
end

