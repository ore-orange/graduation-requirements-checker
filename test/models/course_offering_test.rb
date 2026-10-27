# frozen_string_literal: true

require 'test_helper'

class CourseOfferingTest < ActiveSupport::TestCase
  test '講義コードは必須' do
    offering = build_offering(lecture_code: nil)
    assert_not offering.valid?
  end

  test '同じ年度・学期で講義コードは重複できない' do
    build_offering(lecture_code: 'k001').save!
    assert_not build_offering(lecture_code: 'k001').valid?
  end

  test '年度が違えば同じ講義コードを登録できる' do
    build_offering(year: 2026, lecture_code: 'k001').save!
    assert build_offering(year: 2027, lecture_code: 'k001').valid?
  end

  test '年度・学科は空でもよい' do
    assert build_offering(year: nil, department: nil).valid?
  end

  private

  def build_offering(**overrides)
    defaults = { course: Course.create!(name: '情報処理概論', credits: 2), department: sample_department,
                 semester: '前期', year: 2026, lecture_code: 'k00123001' }
    CourseOffering.new(**defaults, **overrides)
  end
end

