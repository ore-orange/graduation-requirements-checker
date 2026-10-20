# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # ページ画像の置き場は、実行ごと・並列のワーカーごとに分ける。
    # 共有すると、別のワーカーや開発環境の画像を消し合う。
    TimetableUpload.images_root = Rails.root.join('tmp/test_images/0')

    parallelize_setup { |worker| TimetableUpload.images_root = Rails.root.join('tmp/test_images', worker.to_s) }
    parallelize_teardown { |worker| FileUtils.rm_rf(Rails.root.join('tmp/test_images', worker.to_s)) }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

