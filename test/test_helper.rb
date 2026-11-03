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

    # 便覧の下書きの画像も同じ。取り込みの id と同じ数字が並ぶので、置き場は別にする。
    Curriculum.images_root = Rails.root.join('tmp/test_curriculum_images/0')

    parallelize_setup do |worker|
      TimetableUpload.images_root = Rails.root.join('tmp/test_images', worker.to_s)
      Curriculum.images_root = Rails.root.join('tmp/test_curriculum_images', worker.to_s)
    end
    parallelize_teardown do |worker|
      FileUtils.rm_rf(Rails.root.join('tmp/test_images', worker.to_s))
      FileUtils.rm_rf(Rails.root.join('tmp/test_curriculum_images', worker.to_s))
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # 講義の分類に使う学科。1つのテストの中では同じものを返す。
    # test_ で始める名前にすると、Minitestがテストメソッドとして拾ってしまうので避ける。
    def sample_department
      @sample_department ||= Faculty.create!(name: 'テスト学部').departments.create!(name: 'テスト学科')
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # 便覧を操作したあとに戻る、卒業要件の確認画面。その便覧の学部・学科コース・入学年度を選んだ状態で開く。
    # 学部名か学科コース名が無い古い行は選べないので、選択なしの画面になる。
    def requirements_path_for(curriculum)
      selection = { faculty: curriculum.faculty_name, department: curriculum.department_name,
                    admission_year: curriculum.admission_year }
      selection.values.all?(&:present?) ? requirements_path(selection) : requirements_path
    end
  end
end

