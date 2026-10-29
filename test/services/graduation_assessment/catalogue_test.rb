# frozen_string_literal: true

require 'test_helper'

class GraduationAssessment
  class CatalogueTest < ActiveSupport::TestCase
    setup do
      # 人工の format 2 文書。実際の便覧は読み込まない。
      @catalogue = Catalogue.new(format2_document)
      @old = Catalogue.new(old_document)
    end

    test 'category_keys は便覧の categories から来る' do
      assert_equal %w[foundation excluded], @catalogue.category_keys
    end

    test 'categories は便覧の定義をそのまま返す' do
      assert_equal [{ 'key' => 'foundation', 'label' => '基礎', 'counts_toward_total' => true },
                    { 'key' => 'excluded', 'label' => '算入対象外', 'counts_toward_total' => false }],
                   @catalogue.categories
    end

    test 'counted_category_keys は counts_toward_total が false の区分を除く' do
      assert_equal ['foundation'], @catalogue.counted_category_keys
    end

    test 'counted_category_keys は counts_toward_total の無い区分を算入する' do
      catalogue = Catalogue.new(format2_document.merge('categories' => [{ 'key' => 'a', 'label' => 'A' }]))

      assert_equal ['a'], catalogue.counted_category_keys
    end

    test 'conditions は rules の並び順どおりに、cap と exclude を除いて返る' do
      assert_equal %w[common_total foreign_language], @catalogue.conditions.map(&:id)
      assert_instance_of Rules::CreditSum, @catalogue.conditions.first
      assert_instance_of Rules::OneOfPaths, @catalogue.conditions.last
    end

    test 'adjustments は cap と exclude だけを rules の並び順どおりに返す' do
      assert_equal %w[natural_cap own_fusion], @catalogue.adjustments.map(&:id)
      assert_instance_of Rules::Cap, @catalogue.adjustments.first
      assert_instance_of Rules::Exclude, @catalogue.adjustments.last
    end

    test 'conditions と adjustments は一度だけ作って使い回す' do
      assert_same @catalogue.conditions, @catalogue.conditions
      assert_same @catalogue.adjustments, @catalogue.adjustments
    end

    test '未知の型の規則は例外にせず conditions に Unknown として残る' do
      document = format2_document.merge('rules' => [{ 'type' => 'mystery', 'id' => 'm' }])

      assert_instance_of Rules::Unknown, Catalogue.new(document).conditions.first
    end

    test '壊れた調整は便覧を読み込む時点で例外になる' do
      bad = { 'type' => 'cap', 'id' => 'bad', 'category' => 'foundation', 'credits' => -1 }

      assert_raises(ArgumentError) { Catalogue.new(format2_document.merge('rules' => [bad])) }
    end

    test 'display は便覧の display を返す' do
      assert_equal({ 'groups' => [] }, @catalogue.display)
    end

    test 'find_by_number は科目番号で科目を引く' do
      assert_equal '離散数学', @catalogue.find_by_number('知能103')['name']
      assert_nil @catalogue.find_by_number('知能999')
    end

    test 'find_by_number は番号の無い科目を引かない' do
      assert_nil @catalogue.find_by_number(nil)
    end

    test 'required_roles は rules があれば one_of_paths の paths から作る' do
      assert_equal %w[university_english english_reading], @catalogue.required_roles
    end

    test 'specified? は rules があれば one_of_paths に挙がった役割の科目を指定科目とする' do
      assert @catalogue.specified?('roles' => ['english_reading'])
      assert_not @catalogue.specified?('roles' => ['other'])
      assert @catalogue.specified?('required' => true, 'roles' => [])
    end

    test '旧形式の便覧でも例外にならず空を返す' do
      assert_empty @old.categories
      assert_empty @old.category_keys
      assert_empty @old.counted_category_keys
      assert_empty @old.conditions
      assert_empty @old.adjustments
      assert_empty @old.display
    end

    test '旧形式の便覧の required_roles は requirements から作る' do
      assert_equal %w[english_a japanese_a calc_1 calc_2 physics_a], @old.required_roles
    end

    test '旧形式の便覧の specified? は requirements に挙がった役割の科目を指定科目とする' do
      assert @old.specified?('roles' => ['calc_2'])
      assert @old.specified?('roles' => ['japanese_a'])
      assert_not @old.specified?('roles' => ['other'])
    end

    test '旧形式の便覧の exclusion は今までどおり' do
      assert_equal '卒業単位への算入対象外', @old.exclusion('category' => 'excluded')
      assert_equal '自コース提供の工学融合科目は登録・算入不可',
                   @old.exclusion('category' => 'fusion', 'provider' => 'intelligent_informatics')
      assert_nil @old.exclusion('category' => 'fusion', 'provider' => 'mechanical')
    end

    private

    def courses
      [{ 'key' => 'discrete', 'number' => '知能103', 'name' => '離散数学', 'category' => 'foundation',
         'credits' => 2, 'required' => false, 'roles' => [] },
       { 'key' => 'nameless', 'number' => nil, 'name' => '番号なし', 'category' => 'foundation',
         'credits' => 2, 'required' => false, 'roles' => [] }]
    end

    def format2_document
      { 'courses' => courses, 'requirements' => {},
        'categories' => [{ 'key' => 'foundation', 'label' => '基礎', 'counts_toward_total' => true },
                         { 'key' => 'excluded', 'label' => '算入対象外', 'counts_toward_total' => false }],
        'rules' => rules, 'display' => { 'groups' => [] } }
    end

    # cap と exclude を条件の間に挟み、振り分けても並び順が保たれることを確かめる。
    def rules
      [{ 'type' => 'credit_sum', 'id' => 'common_total', 'label' => '共通', 'categories' => ['foundation'],
         'required' => 2 },
       { 'type' => 'cap', 'id' => 'natural_cap', 'category' => 'foundation', 'credits' => 2 },
       { 'type' => 'one_of_paths', 'id' => 'foreign_language', 'label' => '外国語',
         'paths' => [['university_english'], ['english_reading']] },
       { 'type' => 'exclude', 'id' => 'own_fusion', 'category' => 'excluded', 'reason' => '自コース提供' }]
    end

    def old_document
      { 'courses' => courses,
        'requirements' => { 'english_roles' => ['english_a'], 'japanese_role' => 'japanese_a',
                            'calculus_paths' => [%w[calc_1 calc_2]], 'physics_roles' => ['physics_a'] } }
    end
  end
end

