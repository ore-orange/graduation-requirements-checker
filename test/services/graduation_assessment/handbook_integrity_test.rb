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

    test '算入を変える3つの調整が便覧にある' do
      assert_equal %w[natural_cap excluded_category own_fusion], @catalogue.adjustments.map(&:id)
    end

    # ゴールデンマスターの7ケースは、どれも selectable: false のこの6科目を入力に含まない。
    # 算入対象外の判定はゴールデンでは守れないので、当たる科目と理由の文面をここで固定する。
    test 'exclude 規則は算入対象外の区分と自コース提供の工学融合にだけ、その理由で当たる' do
      expected = @document.fetch('courses').filter_map { |course| [course.fetch('key'), expected_exclusion(course)] }
                          .to_h.compact
      actual = @document.fetch('courses').to_h { |course| [course.fetch('key'), @catalogue.exclusion(course)] }.compact

      assert_equal 6, expected.size
      assert_equal expected, actual
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

    # 判定側が算入上限を効かせて数える行は、区分の素の合計と食い違う。この3行だけが判定の値を使う。
    # 増減はどちらも画面の数字を静かに変えるので、2024年度の便覧がこうあるべきという期待を直に書く。
    test 'credits_from_check が true なのは general_subtotal・advanced・fusion の3行だけ' do
      from_check = @rows.select { |row| row['credits_from_check'] }

      assert_equal %w[advanced fusion general_subtotal], from_check.pluck('id').sort
    end

    test '算入する区分は21、excluded だけが算入しない' do
      assert_equal 22, @catalogue.category_keys.size
      assert_equal 21, @catalogue.counted_category_keys.size
      assert_equal ['excluded'], @catalogue.category_keys - @catalogue.counted_category_keys
    end

    private

    # 便覧のデータではなく、2024年度の便覧がこう書いてあるべきという期待を直に書く。
    def expected_exclusion(course)
      return '卒業単位への算入対象外' if course['category'] == 'excluded'
      return unless course['category'] == 'fusion' && CourseNumber.prefix(course['number']) == '知能'

      '自コース提供の工学融合科目は登録・算入不可'
    end
  end
end

