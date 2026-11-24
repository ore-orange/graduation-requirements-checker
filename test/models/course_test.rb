# frozen_string_literal: true

require 'test_helper'

# 統合テーブル。便覧(カリキュラムJSON)由来の科目と、授業時間配当表の開講1件が同じ表に入る。
class CourseTest < ActiveSupport::TestCase
  test '同じ年度・学期で講義コードは重複できない' do
    build_course(lecture_code: 'k001').save!

    assert_not build_course(lecture_code: 'k001').valid?
  end

  test '年度が違えば同じ講義コードを登録できる' do
    build_course(year: 2026, lecture_code: 'k001').save!

    assert_predicate build_course(year: 2027, lecture_code: 'k001'), :valid?
  end

  # 検証ではなくcheck制約で止まることを確かめるので、生SQLで入れる。
  test '講義コードがあるのに学期が無い行はDBが拒否する' do
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO courses (name, lecture_code, created_at, updated_at)
        VALUES ('情報処理概論', 'k001', now(), now())
      SQL
    end
  end

  test '便覧由来の科目は開講の列がすべて空でよい' do
    course = build_catalogue_course

    assert_predicate course, :valid?
    course.save!
    assert_equal [[], []], [course.grade_years, course.periods]
  end

  test '年度・学科は空でもよい' do
    assert_predicate build_course(year: nil, department: nil), :valid?
  end

  test '必修選択は選択肢の外を拒否する' do
    assert_not build_course(requirement_type: '必').valid?
  end

  test '曜日は選択肢の外を拒否する' do
    assert_not build_course(weekday: '日').valid?
  end

  test 'offered は講義コードを持つ行だけを返す' do
    build_catalogue_course.save!
    offered = build_course(lecture_code: 'k001')
    offered.save!

    assert_equal [offered], Course.offered.to_a
  end

  private

  # 授業時間配当表の開講1件
  def build_course(**overrides)
    defaults = { name: '情報処理概論', credits: 2, department: sample_department,
                 semester: '前期', year: 2026, lecture_code: 'k00123001' }
    Course.new(**defaults, **overrides)
  end

  # 便覧由来の科目。年度・学期・講義コードを持たない。
  def build_catalogue_course
    Course.new(curriculum_key: 'intro', course_number: 'T1234', name: '情報処理概論', credits: 2)
  end
end

