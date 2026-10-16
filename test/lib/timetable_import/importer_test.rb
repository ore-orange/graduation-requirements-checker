# frozen_string_literal: true

require 'test_helper'

module TimetableImport
  class ImporterTest < ActiveSupport::TestCase
    def row(overrides = {})
      { '要確認' => '', '学期' => '前期', '講義コード' => '610000071', '科目番号' => '工共100',
        '科目名' => '工学基礎演習', '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金',
        '時限' => '2・3', '開講区分' => '1Q', '備考' => '' }.merge(overrides)
    end

    test 'dry run reports counts but saves nothing' do
      result = nil
      assert_no_difference ['Course.count', 'CourseOffering.count'] do
        result = Importer.new([row]).call
      end

      assert_predicate result, :ok?
      assert_not result.applied
      assert_equal 1, result.created_courses
      assert_equal 1, result.created_offerings
    end

    test 'apply saves the course and its offering' do
      result = Importer.new([row]).call(apply: true)

      assert result.applied
      offering = CourseOffering.find_by!(lecture_code: '610000071')
      assert_equal '工共100', offering.course.course_number
      assert_equal 2, offering.course.credits
      assert_equal [1], offering.grade_years
      assert_equal [2, 3], offering.periods
      assert_equal %w[前期 必修 金 1Q], [offering.semester, offering.requirement_type, offering.weekday, offering.term_type]
    end

    test 'stores intensive courses without weekday or periods' do
      Importer.new([row('曜日' => '', '時限' => '', '開講区分' => '集中', '受講年次' => '2・3・4')]).call(apply: true)

      offering = CourseOffering.find_by!(lecture_code: '610000071')
      assert_nil offering.weekday
      assert_equal [], offering.periods
      assert_equal [2, 3, 4], offering.grade_years
    end

    test 'running twice does not duplicate and reports unchanged' do
      Importer.new([row]).call(apply: true)
      result = Importer.new([row]).call(apply: true)

      assert_equal 0, result.created_courses
      assert_equal 1, result.unchanged_offerings
      assert_equal 1, CourseOffering.count
    end

    test 'changed values update the existing offering' do
      Importer.new([row]).call(apply: true)
      result = Importer.new([row('曜日' => '月')]).call(apply: true)

      assert_equal 1, result.updated_offerings
      assert_equal '月', CourseOffering.find_by!(lecture_code: '610000071').weekday
    end

    test 'same course in the other semester reuses the course' do
      Importer.new([row]).call(apply: true)
      Importer.new([row('学期' => '後期')]).call(apply: true)

      assert_equal 1, Course.where(course_number: '工共100').count
      assert_equal %w[前期 後期], CourseOffering.order(:semester).pluck(:semester).sort
    end

    test 'unresolved review flag blocks the whole import' do
      result = nil
      assert_no_difference ['Course.count', 'CourseOffering.count'] do
        result = Importer.new([row, row('講義コード' => '610002071', '要確認' => '時限が不明')]).call(apply: true)
      end

      assert_not result.ok?
      assert_not result.applied
      assert_match(/2行目.*要確認/, result.errors.first)
    end

    test 'rejects malformed values with the row number' do
      result = Importer.new([row('必修選択' => '必', '曜日' => '日', '時限' => '4(・5)', '単位' => 'abc')]).call

      assert_equal 4, result.errors.size
      assert(result.errors.all? { |message| message.start_with?('1行目') })
      %w[単位 必修選択 曜日 時限].each { |label| assert(result.errors.any? { |message| message.include?(label) }) }
    end

    test 'credits must be whole numbers' do
      ['1.5', '2.0', '-1', '1000', ''].each do |value|
        result = Importer.new([row('単位' => value)]).call
        assert_not result.ok?, "単位 #{value.inspect} は拒否されるはず"
        assert_includes result.errors.first, '整数'
      end
    end

    test 'credit mismatch with a registered course is an error, not an overwrite' do
      Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 1)
      result = Importer.new([row]).call(apply: true)

      assert_not result.ok?
      assert_equal 1, Course.find_by!(course_number: '工共100').credits
      assert_equal 0, CourseOffering.count
    end
  end
end

