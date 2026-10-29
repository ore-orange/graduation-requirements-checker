# frozen_string_literal: true

require 'test_helper'

# 実物の2024年度の便覧（format 2）が、画面と判定の両方から引ける形で整っているかを確かめる。
# check_ids の綴り違いや、どの行にも出ない区分は、エラーにならないまま学生の科目を見えなくする。
class GraduationAssessment
  class HandbookIntegrityTest < ActiveSupport::TestCase
    PATH = Rails.root.join('config/curricula/intelligent_informatics/2024.json')
    CONDITION_IDS = %w[
      health humanities social general_integrated general_without_natural general_subtotal
      japanese english_required foreign_language common_total
      basic_total calculus physics
      required_all required_information required_comprehensive required_research required_math required_core
      required_total elective_inner elective_total fusion_provider total
    ].freeze

    setup do
      @document = JSON.parse(PATH.read)
      @catalogue = Catalogue.new(@document)
      @rows = @document.fetch('display').fetch('groups').flat_map { |group| group.fetch('rows') }
    end

    test '便覧は Catalogue に例外なく読み込める' do
      assert_equal 2, @document['format_version']
      assert_nothing_raised { Catalogue.new(JSON.parse(PATH.read)) }
    end

    test '24個の条件の id が、画面に出る順のとおりに並ぶ' do
      assert_equal CONDITION_IDS, @catalogue.conditions.map(&:id)
    end

    test 'display の行の check_ids は存在する規則を指す' do
      known = @catalogue.conditions.map(&:id)

      assert_empty @rows.flat_map { |row| row.fetch('check_ids') } - known
    end

    test 'display の章と小計の check_id・check_ids も存在する規則を指す' do
      known = @catalogue.conditions.map(&:id)
      display = @document.fetch('display')

      assert_empty display.fetch('groups').pluck('check_id') - known
      assert_empty display.fetch('subtotals').flat_map { |subtotal| subtotal.fetch('check_ids') } - known
    end

    test 'display の行の categories は存在する区分を指す' do
      assert_empty @rows.flat_map { |row| row.fetch('categories') } - @catalogue.category_keys
    end

    test 'excluded 以外のすべての区分が、どれかの display の行に現れる' do
      shown = @rows.flat_map { |row| row.fetch('categories') }

      assert_empty @catalogue.category_keys - ['excluded'] - shown
    end

    test '算入する区分は21、excluded だけが算入しない' do
      assert_equal 22, @catalogue.category_keys.size
      assert_equal 21, @catalogue.counted_category_keys.size
      assert_equal ['excluded'], @catalogue.category_keys - @catalogue.counted_category_keys
    end
  end
end

