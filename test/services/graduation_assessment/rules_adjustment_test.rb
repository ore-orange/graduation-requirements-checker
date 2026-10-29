# frozen_string_literal: true

require 'test_helper'

class GraduationAssessment
  class RulesAdjustmentTest < ActiveSupport::TestCase
    setup do
      # 人工の科目で、手書きの定義だけを評価する。実際の便覧は読み込まない。
      # 挿入順とキー順が食い違うよう、n_c・n_a・n_b の順に台帳へ入れる。
      @courses = [
        course('n_a', 'natural', 2),
        course('n_b', 'natural', 2),
        course('n_c', 'natural', 2),
        course('half', 'natural', 1),
        course('en_1', 'english', 4)
      ]
      @catalogue = catalogue_with(categories: [{ 'key' => 'natural', 'label' => '自然系' }])
      @ledger = Ledger.new(@catalogue)
    end

    test 'adjustment は cap と exclude を作る' do
      assert_instance_of Rules::Cap, cap
      assert_instance_of Rules::Exclude,
                         Rules.adjustment('type' => 'exclude', 'category' => 'excluded', 'reason' => 'r')
    end

    test 'cap と exclude は条件としては作れず Unknown になる' do
      assert_instance_of Rules::Unknown, Rules.condition(cap_definition)
      assert_instance_of Rules::Unknown, Rules.condition('type' => 'exclude', 'category' => 'excluded', 'reason' => 'r')
    end

    test '条件の型は調整としては作れず例外になる' do
      assert_raises(ArgumentError) { Rules.adjustment('type' => 'credit_sum', 'id' => 'x') }
      assert_raises(ArgumentError) { Rules.adjustment('type' => 'gpa') }
      assert_raises(ArgumentError) { Rules.adjustment(nil) }
    end

    test 'cap は区分の算入をキー順に打ち切る' do
      count('n_c', 'n_a', 'n_b')

      cap.apply(@catalogue, @ledger)

      assert_equal BigDecimal('2'), @ledger.sum(['natural'])
      assert_equal BigDecimal('2'), @ledger.items['n_a'].counted
      assert_equal BigDecimal('0'), @ledger.items['n_b'].counted
      assert_equal BigDecimal('0'), @ledger.items['n_c'].counted
    end

    test 'cap は上限に収まらない科目に、残りだけを算入する' do
      count('n_c', 'half', 'n_a')

      cap.apply(@catalogue, @ledger)

      assert_equal BigDecimal('2'), @ledger.sum(['natural'])
      assert_equal BigDecimal('1'), @ledger.items['half'].counted
      assert_equal BigDecimal('1'), @ledger.items['n_a'].counted
      assert_equal BigDecimal('0'), @ledger.items['n_c'].counted
    end

    test 'cap は打ち切った科目に理由を残す' do
      count('n_c', 'half', 'n_a')

      cap.apply(@catalogue, @ledger)

      assert_equal '自然系は卒業算入上限2単位（この科目は1.0単位を算入）', @ledger.items['n_a'].reason
      assert_equal '自然系は卒業算入上限2単位（この科目は0.0単位を算入）', @ledger.items['n_c'].reason
    end

    test 'cap は上限に収まった科目と他の区分を変えない' do
      count('half', 'en_1')

      cap.apply(@catalogue, @ledger)

      assert_equal BigDecimal('1'), @ledger.items['half'].counted
      assert_equal '卒業単位に算入', @ledger.items['half'].reason
      assert_equal BigDecimal('4'), @ledger.items['en_1'].counted
      assert_equal '卒業単位に算入', @ledger.items['en_1'].reason
    end

    test 'cap は算入されていない科目に上限を使わせない' do
      @ledger.add(@catalogue.find('n_a'), BigDecimal('2'))
      count('n_b')

      cap.apply(@catalogue, @ledger)

      assert_equal BigDecimal('2'), @ledger.items['n_b'].counted
      assert_equal BigDecimal('0'), @ledger.items['n_a'].counted
      assert_equal '卒業単位に算入', @ledger.items['n_a'].reason
    end

    test 'cap の理由は定義の上限と区分名から作る' do
      count('half', 'n_a')

      Rules.adjustment('type' => 'cap', 'id' => 'c', 'category' => 'natural', 'credits' => 1.5)
           .apply(@catalogue, @ledger)

      assert_equal BigDecimal('1.5'), @ledger.sum(['natural'])
      assert_equal '自然系は卒業算入上限1.5単位（この科目は0.5単位を算入）', @ledger.items['n_a'].reason
    end

    test 'cap の理由の区分名は便覧の categories から読む' do
      catalogue = catalogue_with(categories: [{ 'key' => 'natural', 'label' => '自然科学系' }])
      ledger = Ledger.new(catalogue)
      ledger.add(catalogue.find('n_a'), BigDecimal('2')).counted = BigDecimal('2')
      ledger.add(catalogue.find('n_b'), BigDecimal('2')).counted = BigDecimal('2')

      cap.apply(catalogue, ledger)

      assert_equal '自然科学系は卒業算入上限2単位（この科目は0.0単位を算入）', ledger.items['n_b'].reason
    end

    test 'cap の理由の区分名は categories がなければ区分のキーで代える' do
      [catalogue_with, catalogue_with(categories: [{ 'key' => 'english', 'label' => '英語' }])].each do |catalogue|
        ledger = Ledger.new(catalogue)
        ledger.add(catalogue.find('n_a'), BigDecimal('2')).counted = BigDecimal('2')
        ledger.add(catalogue.find('n_b'), BigDecimal('2')).counted = BigDecimal('2')

        cap.apply(catalogue, ledger)

        assert_equal 'naturalは卒業算入上限2単位（この科目は0.0単位を算入）', ledger.items['n_b'].reason
      end
    end

    test 'label_for は区分の和名を返し、なければキーを返す' do
      assert_equal '自然系', @catalogue.label_for('natural')
      assert_equal 'english', @catalogue.label_for('english')
      assert_equal 'natural', catalogue_with.label_for('natural')
    end

    test 'cap は credits が0でも作れて、区分を丸ごと切る' do
      count('n_a', 'half')

      Rules.adjustment(cap_definition.merge('credits' => 0)).apply(@catalogue, @ledger)

      assert_equal BigDecimal('0'), @ledger.sum(['natural'])
      assert_equal '自然系は卒業算入上限0単位（この科目は0.0単位を算入）', @ledger.items['n_a'].reason
    end

    test '同じ区分に2つの cap があれば、小さい上限に収まる' do
      count('n_a', 'n_b', 'n_c')

      Rules.adjustment(cap_definition.merge('id' => 'wide', 'credits' => 4)).apply(@catalogue, @ledger)
      assert_equal BigDecimal('4'), @ledger.sum(['natural'])
      cap.apply(@catalogue, @ledger)

      assert_equal BigDecimal('2'), @ledger.sum(['natural'])
      assert_equal BigDecimal('2'), @ledger.items['n_a'].counted
    end

    test 'cap は credits が負・非数・Infinity・欠けていれば作れない' do
      [-1, '2', 'Infinity', Float::INFINITY, Float::NAN, nil, ''].each do |credits|
        assert_raises(ArgumentError, "credits=#{credits.inspect}") do
          Rules.adjustment(cap_definition.merge('credits' => credits))
        end
      end
      assert_raises(ArgumentError) { Rules.adjustment(cap_definition.except('credits')) }
    end

    test 'exclude は reason がなければ作れない' do
      [nil, '', 3].each do |reason|
        assert_raises(ArgumentError) do
          Rules.adjustment('type' => 'exclude', 'category' => 'excluded', 'reason' => reason)
        end
      end
      assert_raises(ArgumentError) { Rules.adjustment('type' => 'exclude', 'category' => 'excluded') }
    end

    test 'exclude は category がなければ作れない' do
      assert_raises(ArgumentError) { Rules.adjustment('type' => 'exclude', 'reason' => 'r') }
      assert_raises(ArgumentError) { Rules.adjustment('type' => 'exclude', 'category' => '', 'reason' => 'r') }
    end

    test 'exclude は number_prefix が nil・空・空白入り・全角なら作れない' do
      [nil, '', '知能 ', ' 知能', '知 能', 'Ｃ', '知能1', 3].each do |prefix|
        assert_raises(ArgumentError, "number_prefix=#{prefix.inspect}") do
          Rules.adjustment('type' => 'exclude', 'category' => 'fusion', 'number_prefix' => prefix, 'reason' => 'r')
        end
      end
    end

    test 'exclude は number_prefix を持たない定義と、読める接頭辞の定義を作れる' do
      assert_instance_of Rules::Exclude, Rules.adjustment('type' => 'exclude', 'category' => 'x', 'reason' => 'r')
      %w[知能 C 外].each do |prefix|
        rule = Rules.adjustment('type' => 'exclude', 'category' => 'x', 'number_prefix' => prefix, 'reason' => 'r')
        assert_instance_of Rules::Exclude, rule
      end
    end

    test 'exclude は区分だけの指定で理由を返す' do
      rule = Rules.adjustment('type' => 'exclude', 'category' => 'excluded', 'reason' => '卒業単位への算入対象外')
      assert_equal '卒業単位への算入対象外', rule.reason_for('category' => 'excluded', 'number' => '情101')
      assert_nil rule.reason_for('category' => 'fusion', 'number' => '機械991')
    end

    test 'exclude は number_prefix があれば接頭辞も一致したときだけ返す' do
      rule = own_fusion_rule
      assert_equal '自コース提供', rule.reason_for('category' => 'fusion', 'number' => '知能993')
      assert_nil rule.reason_for('category' => 'fusion', 'number' => '機械991')
      assert_nil rule.reason_for('category' => 'basic', 'number' => '知能993')
    end

    test 'exclude は全角などで書かれた科目番号も接頭辞で読む' do
      assert_equal '自コース提供', own_fusion_rule.reason_for('category' => 'fusion', 'number' => '知能９９３')
    end

    test 'exclude は科目番号が読めない科目には当たらない' do
      rule = own_fusion_rule
      assert_nil rule.reason_for('category' => 'fusion', 'number' => nil)
      assert_nil rule.reason_for('category' => 'fusion', 'number' => '')
      assert_nil rule.reason_for('category' => 'fusion', 'number' => 'ドイツ語')
      assert_nil rule.reason_for('category' => 'fusion')
    end

    private

    def course(key, category, credits)
      { 'key' => key, 'name' => "人工科目 #{key}", 'category' => category, 'credits' => credits,
        'number' => nil, 'required' => false, 'roles' => [] }
    end

    def count(*keys)
      keys.each do |key|
        course = @catalogue.find(key)
        @ledger.add(course, BigDecimal(course['credits'].to_s)).counted = BigDecimal(course['credits'].to_s)
      end
    end

    # 区分の和名を引くためだけの便覧。categories を持つ便覧は規則で判定する便覧として検められるので、
    # 読み込めるように条件を1つ置く。
    def catalogue_with(categories: nil)
      document = { 'courses' => @courses }
      if categories
        document['categories'] = categories
        document['rules'] = [{ 'type' => 'credit_sum', 'id' => 'total', 'label' => '合計',
                               'categories' => categories.pluck('key'), 'required_credits' => 2 }]
      end
      Catalogue.new(document)
    end

    def cap_definition
      { 'type' => 'cap', 'id' => 'natural_cap', 'category' => 'natural', 'credits' => 2 }
    end

    def cap
      Rules.adjustment(cap_definition)
    end

    def own_fusion_rule
      Rules.adjustment('type' => 'exclude', 'category' => 'fusion', 'number_prefix' => '知能', 'reason' => '自コース提供')
    end
  end
end

