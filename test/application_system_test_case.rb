# frozen_string_literal: true

require 'test_helper'

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Google Chrome は Linux arm64 版が提供されていないため、コンテナ内では Chromium を使う。
  # CI の runner には本物の Chrome があるので、そちらではこの分岐に入らない。
  CHROMIUM_BINARY = '/usr/bin/chromium'
  CHROMEDRIVER_BINARY = '/usr/bin/chromedriver'
  IN_CONTAINER = File.exist?(CHROMIUM_BINARY)

  # apt で入れた chromedriver を使い、Selenium Manager による自動ダウンロードを避ける。
  # Chromium が居る時だけ指定し、CI の Chrome とバージョンが食い違わないようにする。
  if IN_CONTAINER && File.exist?(CHROMEDRIVER_BINARY)
    Selenium::WebDriver::Chrome::Service.driver_path = CHROMEDRIVER_BINARY
  end

  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400] do |options|
    next unless IN_CONTAINER

    options.binary = CHROMIUM_BINARY
    # コンテナ内では必須。これが無いと Chromium が起動に失敗する
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
  end
end

