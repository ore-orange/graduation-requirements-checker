# frozen_string_literal: true

require 'application_system_test_case'

class HealthCheckTest < ApplicationSystemTestCase
  test 'ヘルスチェックのエンドポイントがブラウザから開ける' do
    visit rails_health_check_path

    assert_selector 'body'
  end
end

