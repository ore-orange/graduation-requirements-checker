# frozen_string_literal: true

require 'test_helper'

class StudentWorkspaceHelperTest < ActionView::TestCase
  setup do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    @courses_by_number = document.fetch('courses').select { |course| course['number'] }
                                 .index_by { |course| course['number'] }
  end

  test '科目の区分は、科目番号で便覧の科目表から引く' do
    course = Course.new(course_number: '知能101', name: 'プログラミング演習Ⅰ')

    assert_equal 'required_information', course_category(course, @courses_by_number)
  end

  test '自由入力計画科目は custom_category で区分が決まる' do
    course = Course.create!(name: '自由入力', credits: 2, custom_category: 'related')

    assert_equal 'related', course_category(course, @courses_by_number)
  end

  test '便覧にも自由入力にも当たらない科目は算入対象外' do
    assert_equal 'excluded', course_category(Course.new(course_number: '他学999', name: '未知'), @courses_by_number)
    assert_equal 'excluded', course_category(Course.new(name: '番号なし'), @courses_by_number)
  end
end

