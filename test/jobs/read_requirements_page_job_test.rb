# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class ReadRequirementsPageJobTest < ActiveJob::TestCase
  setup do
    @draft = Curriculum.create!(slug: 'test_program', admission_year: 2025, document: {},
                                pages: [{ 'page' => 11, 'status' => 'reading', 'started_at' => Time.current.iso8601 }])
  end

  test '下書きのページを読み取る' do
    called = nil
    CurriculumImport::ReadRequirementsPage.stub(:call, ->(curriculum, page) { called = [curriculum.id, page] }) do
      ReadRequirementsPageJob.perform_now(@draft.id, 11)
    end

    assert_equal [@draft.id, 11], called
  end

  test '想定外のエラーでも、読み取り中のまま残さず失敗にする' do
    CurriculumImport::ReadRequirementsPage.stub(:call, ->(*) { raise IOError, 'disk' }) do
      ReadRequirementsPageJob.perform_now(@draft.id, 11)
    end

    entry = @draft.reload.page_entry(11)
    assert_equal 'failed', entry['status']
    assert_equal '読み取りの途中で問題が起きました。もう一度「読み直す」を押してください。', entry['error']
  end

  test '読み取りの間に下書きが消されていたら、何もしない' do
    @draft.destroy

    assert_nothing_raised { ReadRequirementsPageJob.perform_now(@draft.id, 11) }
  end
end

