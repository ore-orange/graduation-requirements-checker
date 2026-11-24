# frozen_string_literal: true

require 'test_helper'

module TimetableImport
  class ImporterTest < ActiveSupport::TestCase
    def row(overrides = {})
      { '要確認' => '', '学期' => '前期', '講義コード' => '610000071', '科目番号' => '工共100',
        '科目名' => '工学基礎演習', '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金',
        '時限' => '2・3', '開講区分' => '1Q', '備考' => '' }.merge(overrides)
    end

    # 年度と学科は行ごとではなく取り込み全体で1つなので、Importerの引数で渡す。
    def importer(rows, year: 2026)
      Importer.new(rows, year: year, department_id: sample_department.id)
    end

    test 'dry run reports counts but saves nothing' do
      result = nil
      assert_no_difference 'Course.count' do
        result = importer([row]).call
      end

      assert_predicate result, :ok?
      assert_not result.applied
      assert_equal 1, result.created
    end

    test '1行が科目と開講の両方の値を持つ' do
      result = importer([row]).call(apply: true)

      assert result.applied
      course = Course.offered.sole
      assert_equal ['工共100', 2, '610000071'], [course.course_number, course.credits, course.lecture_code]
      assert_equal [1], course.grade_years
      assert_equal [2, 3], course.periods
      assert_equal %w[前期 必修 金 1Q], [course.semester, course.requirement_type, course.weekday, course.term_type]
    end

    test 'stores intensive courses without weekday or periods' do
      importer([row('曜日' => '', '時限' => '', '開講区分' => '集中', '受講年次' => '2・3・4')]).call(apply: true)

      course = Course.offered.sole
      assert_nil course.weekday
      assert_equal [], course.periods
      assert_equal [2, 3, 4], course.grade_years
    end

    test '同じ年度・学期・講義コードの取り込みは変更がなければ変更なしになる' do
      importer([row]).call(apply: true)
      result = importer([row]).call(apply: true)

      assert_equal 1, result.unchanged
      assert_equal 1, Course.offered.count
    end

    test '同じ年度・学期・講義コードの取り込みは更新になる' do
      importer([row('曜日' => '月')], year: 2026).call(apply: true)
      result = importer([row('曜日' => '火')], year: 2026).call(apply: true)

      assert_equal 1, Course.offered.count
      assert_equal 1, result.updated
      assert_equal '火', Course.offered.sole.weekday
    end

    test '再取り込みで科目名・単位が変わると、その行が更新される' do
      importer([row]).call(apply: true)
      result = importer([row('科目名' => '工学基礎演習A', '単位' => '3')]).call(apply: true)

      assert_equal 1, result.updated
      course = Course.offered.sole
      assert_equal ['工学基礎演習A', 3], [course.name, course.credits]
    end

    test '年度が違えば別の行として増える' do
      importer([row], year: 2026).call(apply: true)
      result = importer([row], year: 2027).call(apply: true)

      assert_equal 2, Course.offered.count
      assert_equal 1, result.created
      assert_equal [2026, 2027], Course.offered.order(:year).pluck(:year)
    end

    test '学期が違えば別の行として増える' do
      importer([row]).call(apply: true)
      result = importer([row('学期' => '後期')]).call(apply: true)

      assert_equal 1, result.created
      assert_equal %w[前期 後期], Course.offered.order(:semester).pluck(:semester).sort
    end

    test '同じ科目番号・科目名の講義が登録済みでも、止まらず別の行になる' do
      Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 2, semester: '前期',
                     year: 2026, lecture_code: '610009999', department: sample_department)

      result = importer([row]).call(apply: true)

      assert_predicate result, :ok?
      assert_equal 1, result.created
      assert_equal 2, Course.offered.count
    end

    test '同じPDFの中で同じ科目番号・科目名の行は、講義コードごとに別の行になる' do
      result = importer([row, row('講義コード' => '610000072', '時限' => '4')]).call(apply: true)

      assert_equal 2, result.created
      assert_equal 2, Course.offered.count
    end

    test '便覧由来の科目は取り込みに引き当てられない' do
      catalogue = Course.create!(curriculum_key: 'intro', course_number: '工共100',
                                 name: '工学基礎演習', credits: 2)

      importer([row]).call(apply: true)

      assert_nil catalogue.reload.lecture_code
      assert_equal 2, Course.count
    end

    test 'unresolved review flag blocks the whole import' do
      result = nil
      assert_no_difference 'Course.count' do
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

    test '講義コードが空の行はエラーになり、何も保存しない' do
      result = nil
      assert_no_difference 'Course.count' do
        result = importer([row('講義コード' => '')]).call(apply: true)
      end

      assert_not result.applied
      assert_includes result.errors.join, '講義コード'
    end

    test '年度と学科が講義に入る' do
      result = importer([row], year: 2026).call(apply: true)

      assert result.applied
      course = Course.offered.sole
      assert_equal 2026, course.year
      assert_equal sample_department.id, course.department_id
    end
  end
end

