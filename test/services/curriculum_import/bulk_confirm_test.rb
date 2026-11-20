# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/requirements_draft_fixtures'

module CurriculumImport
  # 区分ごとの「まとめて確認する」。対象・指紋は CoursesReview が決める1か所(画面に出す中身とそろえる)ことと、
  # 1科目ずつの確認(CourseEdit)と同じ意味で確認する(review_again・承認の注記の印を外す)ことを確かめる。
  class BulkConfirmTest < ActiveSupport::TestCase
    include RequirementsDraftFixtures

    # reload してから返す。jsonb の列は、保存した直後の(手元に残った)Hash とDBから読み直した Hash とで、
    # 欄の並びが変わることがある(Postgres の内部表現による)。指紋はその並びごと digest にするので、
    # 画面を開くとき(DBから読む)と同じ状態にそろえておかないと、このテストの中だけで指紋がずれる。
    def draft(document: requirements_document)
      Curriculum.create!(slug: 'bulk', admission_year: 2025, faculty_name: '工学部', department_name: '工学科',
                         source_filename: 'handbook.pdf', document: document).reload
    end

    def review_of(record) = CoursesReview.new(RequirementsReview.new(record))

    def rev_of(record, category) = review_of(record).section_revision(category)

    def courses_in(record, category)
      record.reload.document['courses'].select { |course| course['category'] == category }
    end

    def call(record, category:, rev:)
      result = nil
      record.with_lock { result = BulkConfirm.new(record, category: category, rev: rev).call }
      result
    end

    test 'まだ確認していない科目を、区分ごとまとめて確認済みにする' do
      record = draft
      result = call(record, category: 'humanities', rev: rev_of(record, 'humanities'))

      assert_predicate result, :ok?
      assert_equal 3, result.confirmed
      assert(courses_in(record, 'humanities').all? { |course| CourseEdit.confirmed?(course) })
      # 他の区分には触れない。
      assert(courses_in(record, 'english').none? { |course| course['confirmed'] })
    end

    test 'もう全部確認済みの区分は、0件のまま成功を返す' do
      record = draft
      call(record, category: 'humanities', rev: rev_of(record, 'humanities'))
      result = call(record, category: 'humanities', rev: rev_of(record, 'humanities'))

      assert_predicate result, :ok?
      assert_equal 0, result.confirmed
      assert_match '全部確認済み', result.message
    end

    test '最初に見る科目(要確認の理由がある)は、まとめて確認の対象にならない' do
      document = requirements_document
      document['courses'][0]['review_reason'] = '単位が読み取れません' # 人101 を最初に見る科目にする
      record = draft(document: document)

      result = call(record, category: 'humanities', rev: rev_of(record, 'humanities'))

      assert_predicate result, :ok?
      assert_equal 2, result.confirmed, '最初に見る1件を除いた、残り2件だけが対象'
      assert_not CourseEdit.confirmed?(courses_in(record, 'humanities').find { |course| course['number'] == '人101' })
      assert(courses_in(record, 'humanities').reject { |course| course['number'] == '人101' }
                                             .all? { |course| CourseEdit.confirmed?(course) })
    end

    test '確認したあとに承認の注記が付いた科目(review_again)は、最初に見る科目のままで、まとめて確認の対象にならない' do
      # review_again は「最初に見る科目」に出す印でもある(もう一度、人の目で見てほしいという合図)。
      # まとめて確認がそれを素通りさせては、承認が変わったことに誰も気づかないまま公開されうる。
      document = requirements_document
      document['courses'][0].merge!('confirmed' => true, ApprovalNotes::REVIEW_AGAIN => true,
                                    ApprovalNotes::BY_NOTE => true)
      record = draft(document: document)

      result = call(record, category: 'humanities', rev: rev_of(record, 'humanities'))

      assert_predicate result, :ok?
      assert_equal 2, result.confirmed, '人102・人103 だけが対象。review_again の人101 には触れない'
      course = courses_in(record, 'humanities').find { |entry| entry['number'] == '人101' }
      assert_equal true, course['confirmed']
      assert_equal true, course[ApprovalNotes::REVIEW_AGAIN], 'もう一度見る印は、まとめて確認では外さない(個別に見るまで残す)'
      assert_equal true, course[ApprovalNotes::BY_NOTE]
    end

    test '画面を開いたあとに区分の中身が変わっていれば、1件も確認せず断る' do
      record = draft
      rev = rev_of(record, 'humanities')
      document = record.document.deep_dup
      document['courses'][0]['name'] = '哲学(改)' # 開いたあとに誰かが直した
      record.update!(document: document)

      result = call(record, category: 'humanities', rev: rev)

      assert_not result.ok?
      assert_equal 0, result.confirmed
      assert_match '変わっています', result.message
      assert(courses_in(record, 'humanities').none? { |course| course['confirmed'] })
    end

    test '指紋が空・違う形なら、画面を開いたときと変わったとみなして断る' do
      record = draft

      assert_not call(record, category: 'humanities', rev: '').ok?
      assert_not call(record, category: 'humanities', rev: 'でたらめ').ok?
      assert(courses_in(record, 'humanities').none? { |course| course['confirmed'] })
    end

    test '区分が存在しなければ、見つからないと答える' do
      record = draft

      result = call(record, category: 'nothing', rev: 'x')

      assert_not result.ok?
      assert_match '見つかりません', result.message
    end
  end
end

