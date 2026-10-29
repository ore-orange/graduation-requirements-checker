# frozen_string_literal: true

require 'test_helper'

class StudentWorkspaceHelperTest < ActionView::TestCase
  setup do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    @courses_by_number = document.fetch('courses').select { |course| course['number'] }
                                 .index_by { |course| course['number'] }
    @curriculum = document
  end

  test '章立ては便覧の display から来る' do
    assert_equal ['1. 共通教育', '2. 専門基礎教育', '3. 専門必修科目', '4. 専門選択科目'],
                 planner_groups(@curriculum).pluck(:title)
  end

  test '章と行はシンボルキーで、必要単位は req・req_label で引ける' do
    common, _basic, _required, elective = planner_groups(@curriculum)
    health = common[:rows].first
    inner = elective[:rows].first

    assert_equal 30, common[:req]
    assert_equal 'common_total', common[:check_id]
    assert_equal({ id: 'health', name: '健康運動系', subtitle: '共通教育・教養領域', req: 2, req_label: nil,
                   categories: ['health'], check_ids: ['health'], credits_from_check: false }, health)
    assert_nil inner[:req]
    assert_equal '内数22単位枠', inner[:req_label]
  end

  test '章立ては便覧を書き換えればその通りに変わる' do
    @curriculum['display']['groups'].first['title'] = '1. 別の章'
    @curriculum['display']['groups'].first['rows'].first['required_credits'] = 99

    assert_equal '1. 別の章', planner_groups(@curriculum).first[:title]
    assert_equal 99, planner_groups(@curriculum).first[:rows].first[:req]
  end

  test 'display が無い便覧は黙って別の章立てにせず例外にする' do
    assert_raises(KeyError) { planner_groups(@curriculum.except('display')) }
  end

  test '区分の和名は便覧の categories から来る' do
    assert_equal '健康運動系', category_label('health', @curriculum)
    @curriculum['categories'].find { |category| category['key'] == 'health' }['label'] = '別の名前'

    assert_equal '別の名前', category_label('health', @curriculum)
  end

  test '便覧に無い区分は、キーをそのまま名前にする' do
    assert_equal 'unknown_category', category_label('unknown_category', @curriculum)
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

