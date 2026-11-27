# frozen_string_literal: true

require 'test_helper'

class RequirementsMergeTest < ActiveSupport::TestCase
  Merge = CurriculumImport::RequirementsMerge

  def answer(categories: [], rules: [], groups: [], total: nil)
    { 'categories' => categories.map { |key| { 'key' => key, 'label' => key } }, 'roles' => [],
      'rules' => rules.map { |id| { 'id' => id, 'type' => 'credit_sum' } },
      'display' => { 'total_credits' => total, 'groups' => groups } }
  end

  def group(id, rows)
    { 'id' => id, 'title' => id, 'rows' => rows.map { |row| { 'id' => row, 'name' => row } } }
  end

  test '読み取った区分・規則・章立てを足し、このページが足したものを返す' do
    document, contributed, warnings = Merge.merge({}, answer(categories: %w[health], rules: %w[health_rule],
                                                             groups: [group('common', %w[health])], total: 130))

    assert_equal 2, document['format_version']
    assert_equal %w[health], document['categories'].pluck('key')
    assert_equal %w[health_rule], document['rules'].pluck('id')
    assert_equal 130, document.dig('display', 'total_credits')
    assert_equal({ 'categories' => %w[health], 'roles' => [], 'rules' => %w[health_rule], 'groups' => %w[common],
                   'rows' => [], 'total_credits' => true }, contributed)
    assert_empty warnings
  end

  test '別のページが先に足したものと重なれば、先のものを残して警告する' do
    first, = Merge.merge({}, answer(categories: %w[health], rules: %w[rule], total: 130))
    second, contributed, warnings = Merge.merge(first,
                                                answer(categories: %w[health social], rules: %w[rule], total: 124))

    assert_equal %w[health social], second['categories'].pluck('key')
    assert_equal %w[social], contributed['categories']
    assert_empty contributed['rules']
    assert_equal 130, second.dig('display', 'total_credits')
    assert_equal 3, warnings.size
  end

  test '同じ見出しが次のページに続くときは、行だけを足す' do
    first, = Merge.merge({}, answer(groups: [group('elective', %w[fusion])]))
    second, contributed, = Merge.merge(first, answer(groups: [group('elective', %w[fusion advanced])]))

    assert_equal([%w[fusion advanced]], second.dig('display', 'groups').map { |item| item['rows'].pluck('id') })
    assert_equal [%w[elective advanced]], contributed['rows']
  end

  test 'このページが足したものだけを外す' do
    first, first_contributed, = Merge.merge({}, answer(categories: %w[health], groups: [group('common', %w[health])],
                                                       total: 130))
    second, second_contributed, = Merge.merge(first, answer(categories: %w[social],
                                                            groups: [group('common', %w[social])]))

    without_second = Merge.withdraw(second, second_contributed)
    assert_equal first, without_second.merge('format_version' => 2)

    without_first = Merge.withdraw(second, first_contributed)
    assert_equal %w[social], without_first['categories'].pluck('key')
    assert_empty without_first.dig('display', 'groups')
    assert_nil without_first.dig('display', 'total_credits')
  end

  test '2024年度の便覧と同じ形の読み取りは、そのまま画面と判定に使える' do
    handbook = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    read = { 'categories' => handbook['categories'], 'roles' => [], 'rules' => handbook['rules'],
             'display' => handbook['display'] }

    document, = Merge.merge({}, read)
    document['courses'] = handbook['courses']

    assert_equal 130, CurriculumLayout.new(document).total_credits
    result = GraduationAssessment.new(curriculum: document).call(completed: [])
    assert_equal :unmet, result.actual.status
  end
end

