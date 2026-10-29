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
      assert_equal %w[foundation fusion excluded], @catalogue.category_keys
    end

    test 'categories は便覧の定義をそのまま返す' do
      assert_equal [{ 'key' => 'foundation', 'label' => '基礎', 'counts_toward_total' => true },
                    { 'key' => 'fusion', 'label' => '工学融合', 'counts_toward_total' => true },
                    { 'key' => 'excluded', 'label' => '算入対象外', 'counts_toward_total' => false }],
                   @catalogue.categories
    end

    test 'counted_category_keys は counts_toward_total が false の区分を除く' do
      assert_equal %w[foundation fusion], @catalogue.counted_category_keys
    end

    test 'counted_category_keys は counts_toward_total の無い区分を算入する' do
      document = format2_document.merge('categories' => [{ 'key' => 'a', 'label' => 'A' }], 'rules' => [])

      assert_equal ['a'], Catalogue.new(document).counted_category_keys
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

    test 'course_for は科目番号で科目を引く' do
      assert_equal '離散数学', @catalogue.course_for('知能103')['name']
      assert_nil @catalogue.course_for('知能999')
    end

    test 'course_for は番号の無い科目を引かない' do
      assert_nil @catalogue.course_for(nil)
    end

    test 'required_roles は rules があれば one_of_paths の paths から作る' do
      assert_equal %w[university_english english_reading], @catalogue.required_roles
    end

    test 'specified? は rules があれば one_of_paths に挙がった役割の科目を指定科目とする' do
      assert @catalogue.specified?('roles' => ['english_reading'])
      assert_not @catalogue.specified?('roles' => ['other'])
      assert @catalogue.specified?('required' => true, 'roles' => [])
    end

    test 'exclusion は exclude 規則の理由を返す' do
      assert_equal '自コース提供', @catalogue.exclusion('category' => 'fusion', 'number' => '知能993')
    end

    test 'exclusion は exclude 規則に当たらない科目には nil を返す' do
      assert_nil @catalogue.exclusion('category' => 'fusion', 'number' => '機械101')
      assert_nil @catalogue.exclusion('category' => 'foundation', 'number' => '知能103')
    end

    test 'exclude 規則の無い便覧は何も除外しない' do
      assert_nil @old.exclusion('category' => 'excluded')
      assert_nil @old.exclusion('category' => 'fusion', 'number' => '知能993')
    end

    test '旧形式の便覧でも例外にならず空を返す' do
      assert_empty @old.categories
      assert_empty @old.category_keys
      assert_empty @old.counted_category_keys
      assert_empty @old.conditions
      assert_empty @old.adjustments
      assert_empty @old.display
      assert_empty @old.required_roles
    end

    test '科目番号が重複する便覧は読み込み時に例外になる' do
      duplicated = courses + [course('another', '知能103')]

      error = assert_raises(ArgumentError) { Catalogue.new(format2_document.merge('courses' => duplicated)) }
      assert_includes error.message, '知能103'
    end

    test '番号の無い科目が複数あっても重複として弾かない' do
      nameless = courses + [course('another', nil), course('third', '')]

      assert_nothing_raised { Catalogue.new(format2_document.merge('courses' => nameless)) }
    end

    test 'key の無い区分がある便覧は読み込み時に例外になる' do
      categories = [{ 'key' => 'foundation', 'label' => '基礎' }, { 'label' => '名無し' }]

      assert_raises(ArgumentError) { Catalogue.new(format2_document.merge('categories' => categories)) }
    end

    test 'key が重複する区分がある便覧は読み込み時に例外になる' do
      categories = [{ 'key' => 'foundation', 'label' => '基礎' }, { 'key' => 'foundation', 'label' => '別名' }]

      error = assert_raises(ArgumentError) { Catalogue.new(format2_document.merge('categories' => categories)) }
      assert_includes error.message, 'foundation'
    end

    test 'categories に無い区分を参照する規則は読み込み時に例外になる' do
      rule = { 'type' => 'credit_sum', 'id' => 'ghost', 'label' => '幽霊', 'categories' => ['nowhere'] }

      error = assert_raises(ArgumentError) { Catalogue.new(format2_document.merge('rules' => [rule])) }
      assert_includes error.message, 'nowhere'
    end

    test '入れ子の規則が参照する区分も読み込み時に検める' do
      rule = { 'type' => 'any_of', 'id' => 'nested', 'label' => '入れ子', 'options' => [
        { 'type' => 'all_of', 'conditions' => [{ 'type' => 'grouped_max', 'category' => 'nowhere',
                                                 'group_by' => 'number_prefix', 'required_credits' => 4 }] }
      ] }

      error = assert_raises(ArgumentError) { Catalogue.new(format2_document.merge('rules' => [rule])) }
      assert_includes error.message, 'nowhere'
    end

    test 'paths の無い one_of_paths は学生の判定中ではなく読み込み時に落ちる' do
      rule = { 'type' => 'one_of_paths', 'id' => 'pathless', 'label' => '経路なし' }

      assert_raises(KeyError) { Catalogue.new(format2_document.merge('rules' => [rule])) }
    end

    private

    def course(key, number)
      { 'key' => key, 'number' => number, 'name' => "科目 #{key}", 'category' => 'foundation',
        'credits' => 2, 'required' => false, 'roles' => [] }
    end

    def courses
      [course('discrete', '知能103').merge('name' => '離散数学'),
       course('nameless', nil).merge('name' => '番号なし')]
    end

    def format2_document
      { 'format_version' => 2, 'courses' => courses,
        'categories' => [{ 'key' => 'foundation', 'label' => '基礎', 'counts_toward_total' => true },
                         { 'key' => 'fusion', 'label' => '工学融合', 'counts_toward_total' => true },
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
       { 'type' => 'exclude', 'id' => 'own_fusion', 'category' => 'fusion', 'number_prefix' => '知能',
         'reason' => '自コース提供' }]
    end

    def old_document
      { 'courses' => courses }
    end
  end
end

