# frozen_string_literal: true

require 'test_helper'
require_relative '../support/requirements_draft_fixtures'

# load_draft は下書きのときだけ画面を通すが、その先の操作が行をロックするまでの間に、公開(Publication)が
# 先に完了していることがある(publish も with_lock で同じ行をロックするので、ロックの順番しだいで先に公開が済む)。
# この窓を突く操作(update・update_rules・destroy・update_courses・bulk_confirm_courses)は、ロックの中で
# もう一度公開済みかを確かめ、公開済みの行には1つも変更を残さないことを確かめる。
class CurriculaPublishRaceTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures
  include RequirementsScreenHelpers

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    Curriculum.find_each { |curriculum| FileUtils.rm_rf(curriculum.images_dir) }
  end

  # load_draft の1回目の呼び出しだけ false(下書きとして画面を通す)を返し、以後は true(ロックの中で公開済みに
  # 変わっていたことにする)を返す。操作のまさに途中で公開が完了した状況を、本物のスレッドを使わずに作る。
  def simulate_race_after_load_draft
    calls = 0
    original = Curriculum.instance_method(:published?)
    Curriculum.define_method(:published?) do
      calls += 1
      calls > 1
    end
    yield
  ensure
    Curriculum.define_method(:published?, original)
  end

  PUBLISHED_ALERT = '公開済みの便覧は、この画面からは開けません。'

  test 'ページの指定を保存する途中で公開されていたら、何も変えずに断る' do
    record = draft
    before = record.reload.pages

    simulate_race_after_load_draft do
      patch curriculum_path(record), params: { pages: { '3' => 'courses' } }, env: ENV_LOCAL
    end

    assert_redirected_to requirements_path
    assert_equal PUBLISHED_ALERT, flash[:alert]
    assert_equal before, record.reload.pages
  end

  test '要件表の保存の途中で公開されていたら、何も変えずに断る' do
    record = draft
    before = record.reload.document

    simulate_race_after_load_draft { save(record, categories: {}) }

    assert_redirected_to requirements_path
    assert_equal PUBLISHED_ALERT, flash[:alert]
    assert_equal before, record.reload.document
  end

  test '削除の途中で公開されていたら、消さない' do
    record = draft

    simulate_race_after_load_draft do
      assert_no_difference('Curriculum.count') { delete curriculum_path(record), env: ENV_LOCAL }
    end

    assert_redirected_to requirements_path
    assert_equal PUBLISHED_ALERT, flash[:alert]
    assert Curriculum.exists?(record.id)
  end

  test '科目の確認の途中で公開されていたら、科目に触れない(html)' do
    document = requirements_document
    record = draft(document: document)
    before = record.reload.document

    number = document['courses'][0]['number']
    simulate_race_after_load_draft do
      patch update_courses_curriculum_path(record), params: { number: number, confirmed: true }, env: ENV_LOCAL
    end

    assert_redirected_to requirements_path
    assert_equal PUBLISHED_ALERT, flash[:alert]
    assert_equal before, record.reload.document
  end

  test '科目の確認の途中で公開されていたら、Turbo には conflict を返す' do
    document = requirements_document
    record = draft(document: document)
    stream = { 'Accept' => 'text/vnd.turbo-stream.html' }

    simulate_race_after_load_draft do
      patch update_courses_curriculum_path(record),
            params: { number: document['courses'][0]['number'], confirmed: true }, headers: stream, env: ENV_LOCAL
    end

    assert_response :conflict
  end

  test 'まとめて確認する途中で公開されていたら、何も変えずに断る' do
    document = requirements_document
    record = draft(document: document)
    before = record.reload.document
    rev = CurriculumImport::CoursesReview.new(CurriculumImport::RequirementsReview.new(record)).section_revision('humanities')

    simulate_race_after_load_draft do
      patch bulk_confirm_courses_curriculum_path(record), params: { category: 'humanities', rev: rev }, env: ENV_LOCAL
    end

    assert_redirected_to requirements_path
    assert_equal PUBLISHED_ALERT, flash[:alert]
    assert_equal before, record.reload.document
  end
end

