# frozen_string_literal: true

require 'test_helper'

module TimetableImport
  class ImporterTest < ActiveSupport::TestCase
    def row(overrides = {})
      { '要確認' => '', '学期' => '前期', '講義コード' => '610000071', '科目番号' => '工共100',
        '科目名' => '工学基礎演習', '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金',
        '時限' => '2・3', '開講区分' => '1Q', '備考' => '' }.merge(overrides)
    end

    def linked_row(overrides = {})
      row({ '既存講義ID' => Course.find_by!(course_number: '工共100').id.to_s }.merge(overrides))
    end

    # 年度と学科は行ごとではなく取り込み全体で1つなので、Importerの引数で渡す。
    def importer(rows, year: 2026)
      Importer.new(rows, year: year, department_id: sample_department.id)
    end

    test 'dry run reports counts but saves nothing' do
      result = nil
      assert_no_difference ['Course.count', 'CourseOffering.count'] do
        result = importer([row]).call
      end

      assert_predicate result, :ok?
      assert_not result.applied
      assert_equal 1, result.created_courses
      assert_equal 1, result.created_offerings
    end

    test 'apply saves the course and its offering' do
      result = importer([row]).call(apply: true)

      assert result.applied
      offering = CourseOffering.find_by!(lecture_code: '610000071')
      assert_equal '工共100', offering.course.course_number
      assert_equal 2, offering.course.credits
      assert_equal [1], offering.grade_years
      assert_equal [2, 3], offering.periods
      assert_equal %w[前期 必修 金 1Q], [offering.semester, offering.requirement_type, offering.weekday, offering.term_type]
    end

    test 'stores intensive courses without weekday or periods' do
      importer([row('曜日' => '', '時限' => '', '開講区分' => '集中', '受講年次' => '2・3・4')]).call(apply: true)

      offering = CourseOffering.find_by!(lecture_code: '610000071')
      assert_nil offering.weekday
      assert_equal [], offering.periods
      assert_equal [2, 3, 4], offering.grade_years
    end

    test 'running twice with the existing course chosen does not duplicate and reports unchanged' do
      importer([row]).call(apply: true)
      result = importer([linked_row]).call(apply: true)

      assert_equal 0, result.created_courses
      assert_equal 1, result.unchanged_offerings
      assert_equal 1, CourseOffering.count
    end

    test 'changed values update the existing offering' do
      importer([row]).call(apply: true)
      result = importer([linked_row('曜日' => '月')]).call(apply: true)

      assert_equal 1, result.updated_offerings
      assert_equal '月', CourseOffering.find_by!(lecture_code: '610000071').weekday
    end

    test 'same course in the other semester reuses the chosen course' do
      importer([row]).call(apply: true)
      importer([linked_row('学期' => '後期')]).call(apply: true)

      assert_equal 1, Course.where(course_number: '工共100').count
      assert_equal %w[前期 後期], CourseOffering.order(:semester).pluck(:semester).sort
    end

    test 'unresolved review flag blocks the whole import' do
      result = nil
      assert_no_difference ['Course.count', 'CourseOffering.count'] do
        result = importer([row, row('講義コード' => '610002071', '要確認' => '時限が不明')]).call(apply: true)
      end

      assert_not result.ok?
      assert_not result.applied
      assert_match(/2行目.*要確認/, result.errors.first)
    end

    test 'rejects malformed values with the row number' do
      result = importer([row('必修選択' => '必', '曜日' => '日', '時限' => '4(・5)', '単位' => 'abc')]).call

      assert_equal 4, result.errors.size
      assert(result.errors.all? { |message| message.start_with?('1行目') })
      %w[単位 必修選択 曜日 時限].each { |label| assert(result.errors.any? { |message| message.include?(label) }) }
    end

    test 'credits must be whole numbers' do
      ['1.5', '2.0', '-1', '1000', ''].each do |value|
        result = importer([row('単位' => value)]).call
        assert_not result.ok?, "単位 #{value.inspect} は拒否されるはず"
        assert_includes result.errors.first, '整数'
      end
    end

    test 'a registered course with the same name and number is never merged automatically' do
      Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 2)

      result = nil
      assert_no_difference ['Course.count', 'CourseOffering.count'] do
        result = importer([row]).call(apply: true)
      end

      assert_not result.ok?
      assert_includes result.errors.first, '同じ講義として扱うか、別の講義として登録するか'
    end

    test 'choosing new registers a separate course even if the name and number exist' do
      Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 2)

      result = nil
      assert_difference 'Course.count', 1 do
        result = importer([row('新規登録' => '1')]).call(apply: true)
      end

      assert_predicate result, :ok?
      assert_equal 2, Course.where(course_number: '工共100', name: '工学基礎演習').count
    end

    test 'a course without a number is not matched to anything and stays separate' do
      Course.create!(course_number: nil, name: '工学基礎演習', credits: 2)

      assert_difference 'Course.count', 1 do
        assert_predicate importer([row('科目番号' => '')]).call(apply: true), :ok?
      end
    end

    test 'rows with the same name and number in one import share one new course' do
      rows = [row, row('講義コード' => '610000072', '時限' => '4')]

      assert_difference 'Course.count', 1 do
        result = importer(rows).call(apply: true)
        assert_equal [1, 2], [result.created_courses, result.created_offerings]
      end
    end

    test 'a chosen course that no longer exists is an error' do
      result = importer([row('既存講義ID' => '0')]).call

      assert_not result.ok?
      assert_includes result.errors.first, '選ばれた既存の講義が見つかりません'
    end

    test '年度と学科が開講情報に入る' do
      result = importer([row], year: 2026).call(apply: true)

      assert result.applied
      offering = CourseOffering.sole
      assert_equal 2026, offering.year
      assert_equal sample_department.id, offering.department_id
    end

    test '同じ年度・学期・講義コードの取り込みは更新になる' do
      importer([row('曜日' => '月')], year: 2026).call(apply: true)
      result = importer([linked_row('曜日' => '火')], year: 2026).call(apply: true)

      assert_equal 1, CourseOffering.count
      assert_equal 1, result.updated_offerings
      assert_equal '火', CourseOffering.sole.weekday
    end

    test '年度が違えば別の行として増える' do
      importer([row], year: 2026).call(apply: true)
      result = importer([linked_row], year: 2027).call(apply: true)

      assert_equal 2, CourseOffering.count
      assert_equal 1, result.created_offerings
      assert_equal [2026, 2027], CourseOffering.order(:year).pluck(:year)
    end

    test '講義コードが空の行はエラーになり、何も保存しない' do
      result = nil
      assert_no_difference ['Course.count', 'CourseOffering.count'] do
        result = importer([row('講義コード' => '')]).call(apply: true)
      end

      assert_not result.applied
      assert_includes result.errors.join, '講義コード'
    end

    test 'credit mismatch with a chosen course is an error, not an overwrite' do
      course = Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 1)
      result = importer([row('既存講義ID' => course.id.to_s)]).call(apply: true)

      assert_not result.ok?
      assert_equal 1, Course.find_by!(course_number: '工共100').credits
      assert_equal 0, CourseOffering.count
    end
  end
end

