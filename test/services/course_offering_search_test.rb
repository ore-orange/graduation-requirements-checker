# frozen_string_literal: true

require 'test_helper'

class CourseOfferingSearchTest < ActiveSupport::TestCase
  test '条件が無ければ全件を年度の新しい順で返す' do
    older = create_offering(year: 2025, lecture_code: 'k001')
    newer = create_offering(year: 2026, lecture_code: 'k002')

    assert_equal [newer, older], CourseOfferingSearch.new({}).relation.to_a
  end

  test '年度で絞り込む' do
    create_offering(year: 2025, lecture_code: 'k001')
    hit = create_offering(year: 2026, lecture_code: 'k002')

    assert_equal [hit], CourseOfferingSearch.new(year: '2026').relation.to_a
  end

  test '学部で絞り込むと、その学部の全学科が当たる' do
    hit = create_offering(lecture_code: 'k001', department: sample_department)
    create_offering(lecture_code: 'k002', department: other_department)

    assert_equal [hit], CourseOfferingSearch.new(faculty_id: sample_department.faculty_id.to_s).relation.to_a
  end

  test '学科で絞り込む' do
    create_offering(lecture_code: 'k001', department: sample_department)
    hit = create_offering(lecture_code: 'k002', department: other_department)

    assert_equal [hit], CourseOfferingSearch.new(department_id: other_department.id.to_s).relation.to_a
  end

  test '学部と学科が矛盾するときは0件になる' do
    create_offering(lecture_code: 'k001', department: sample_department)
    search = CourseOfferingSearch.new(faculty_id: other_department.faculty_id.to_s,
                                      department_id: sample_department.id.to_s)

    assert_empty search.relation
  end

  test '科目名は部分一致で当たる' do
    hit = create_offering(lecture_code: 'k001', course_name: '情報処理概論')
    create_offering(lecture_code: 'k002', course_name: '線形代数')

    assert_equal [hit], CourseOfferingSearch.new(name: '情報').relation.to_a
  end

  test '講義コードは大文字小文字を区別しない' do
    hit = create_offering(lecture_code: 'K00123001')

    assert_equal [hit], CourseOfferingSearch.new(lecture_code: 'k00123').relation.to_a
  end

  test 'LIKEのメタ文字は文字そのものとして扱う' do
    hit = create_offering(lecture_code: 'k001', course_number: 'T_1')
    create_offering(lecture_code: 'k002', course_number: 'TX1')

    assert_equal [hit], CourseOfferingSearch.new(course_number: 'T_1').relation.to_a
  end

  test '講義コードの「%」も文字そのものとして扱う' do
    hit = create_offering(lecture_code: 'a%b')
    create_offering(lecture_code: 'azzb')

    assert_equal [hit], CourseOfferingSearch.new(lecture_code: 'a%b').relation.to_a
  end

  test '科目名の「%」も文字そのものとして扱う' do
    hit = create_offering(lecture_code: 'k001', course_name: '情報%論')
    create_offering(lecture_code: 'k002', course_name: '情報理論')

    assert_equal [hit], CourseOfferingSearch.new(name: '情報%論').relation.to_a
  end

  test '年度が空の講義は、年度の新しい順の最後に並ぶ' do
    create_offering(year: 2025, lecture_code: 'k001')
    create_offering(year: nil, lecture_code: 'k002')
    create_offering(year: 2026, lecture_code: 'k003')

    assert_equal [2026, 2025, nil], CourseOfferingSearch.new({}).relation.map(&:year)
  end

  test '学部で絞り込むと、学科が空の講義は外れる' do
    create_offering(lecture_code: 'k001', department: nil)
    hit = create_offering(lecture_code: 'k002', department: sample_department)

    assert_equal [hit], CourseOfferingSearch.new(faculty_id: sample_department.faculty_id.to_s).relation.to_a
  end

  test '年度・学科が空の講義も、条件が無ければ出る' do
    blank = create_offering(lecture_code: 'k001', year: nil, department: nil)

    assert_includes CourseOfferingSearch.new({}).relation, blank
  end

  test 'conditions は指定のあった条件だけを返す' do
    search = CourseOfferingSearch.new(year: '2026', name: '', faculty_id: nil)

    assert_equal({ year: '2026' }, search.conditions)
    assert_predicate search, :filtered?
  end

  test '条件が1つも無ければ filtered? は false' do
    assert_not CourseOfferingSearch.new({}).filtered?
  end

  private

  def other_department
    @other_department ||= Faculty.create!(name: '別学部').departments.create!(name: '別学科')
  end

  def create_offering(course_name: '情報処理概論', course_number: 'T1234', **overrides)
    course = Course.create!(name: course_name, course_number: course_number, credits: 2)
    defaults = { course: course, department: sample_department, semester: '前期', year: 2026 }
    CourseOffering.create!(**defaults, **overrides)
  end
end

