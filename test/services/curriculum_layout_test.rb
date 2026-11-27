# frozen_string_literal: true

require 'test_helper'

class CurriculumLayoutTest < ActiveSupport::TestCase
  DOCUMENT = {
    'categories' => [{ 'key' => 'health', 'label' => '健康運動系' }],
    'display' => {
      'total_credits' => 124,
      'groups' => [
        { 'id' => 'common', 'title' => '1. 共通教育', 'required_credits' => 30, 'check_id' => 'common_total',
          'rows' => [
            { 'id' => 'health', 'name' => '健康運動系', 'subtitle' => '教養領域', 'required_credits' => 2,
              'required_label' => nil, 'categories' => ['health'], 'check_ids' => ['health'],
              'credits_from_check' => false },
            { 'id' => 'general', 'name' => '教養・総合', 'required_credits' => nil, 'required_label' => '内数',
              'categories' => %w[humanities social], 'check_ids' => ['general'], 'credits_from_check' => true }
          ] }
      ]
    }
  }.freeze

  setup do
    @layout = CurriculumLayout.new(DOCUMENT)
  end

  test '章と行を、ビューが使う形で返す' do
    group = @layout.groups.first

    assert_equal({ id: 'common', title: '1. 共通教育', req: 30, check_id: 'common_total' }, group.except(:rows))
    assert_equal({ id: 'general', name: '教養・総合', subtitle: nil, req: nil, req_label: '内数',
                   categories: %w[humanities social], check_ids: ['general'], credits_from_check: true },
                 group[:rows].last)
  end

  test '行・区分・卒業総単位を引ける' do
    assert_equal %w[health general], @layout.rows.pluck(:id)
    assert_equal %w[health humanities social], @layout.mapped_categories
    assert_equal 124, @layout.total_credits
    assert_equal 'common', @layout.find_group('common')[:id]
    assert_nil @layout.find_group('missing')
  end

  test '区分の和名を引き、登録の無い区分はキーのまま返す' do
    assert_equal '健康運動系', @layout.category_label('health')
    assert_equal 'unknown_category', @layout.category_label('unknown_category')
  end

  test '章立ての無い便覧は、初期設定が済んでいないものとして扱う' do
    assert_raises(SetupIncomplete) { CurriculumLayout.new(DOCUMENT.except('display')) }
  end

  test '同梱の2024年度の便覧は、4つの章を持つ' do
    layout = CurriculumLayout.new(curricula(:intelligent_informatics2024).document)

    assert_equal %w[common basic required elective], layout.groups.pluck(:id)
    assert_equal 130, layout.total_credits
    from_check = layout.rows.select { |row| row[:credits_from_check] }.pluck(:id)
    assert_equal %w[advanced fusion general_subtotal], from_check.sort
  end
end

