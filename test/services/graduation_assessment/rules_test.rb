# frozen_string_literal: true

require 'test_helper'

class GraduationAssessment
  class RulesTest < ActiveSupport::TestCase
    setup do
      # 人工の科目で、手書きの定義だけを評価する。実際の便覧は読み込まない。
      @courses = [
        course('health_1', 'health', 2),
        course('st_1', 'basic', 2, roles: ['st_1']),
        course('st_2', 'basic', 2, roles: ['st_2']),
        course('intro_1', 'basic', 2, roles: ['intro_1']),
        course('intro_2', 'basic', 2, roles: ['intro_2']),
        course('required_a', 'required_core', 2, required: true),
        course('required_b', 'required_core', 2, required: true)
      ]
      @catalogue = Catalogue.new('courses' => @courses, 'requirements' => {})
      @ledger = Ledger.new(@catalogue)
    end

    test 'status は充足・要確認・不足の3値を返す' do
      assert_equal :satisfied, Rules.status(true, true)
      assert_equal :needs_review, Rules.status(false, true)
      assert_equal :unmet, Rules.status(false, false)
      assert_equal :unmet, Rules.status(false, nil)
    end

    test 'CreditCheck.status は Rules.status と同じ結果を返す' do
      [true, false].product([true, false]).each do |satisfied, review|
        assert_equal Rules.status(satisfied, review), CreditCheck.status(satisfied, review)
      end
    end

    test 'condition は type に対応する型を返す' do
      assert_instance_of Rules::CreditSum, Rules.condition('type' => 'credit_sum')
      assert_instance_of Rules::AllRequired, Rules.condition('type' => 'all_required')
      assert_instance_of Rules::OneOfPaths, Rules.condition('type' => 'one_of_paths')
    end

    test 'condition は未対応の type を拒まず Unknown にする' do
      assert_instance_of Rules::Unknown, Rules.condition('type' => 'mystery')
    end

    test 'credit_sum は指定区分の算入単位を合計する' do
      count('health_1')
      outcome = rule_health.evaluate(@catalogue, @ledger)

      assert outcome.satisfied
      assert_equal BigDecimal('2'), outcome.counted
      assert_empty outcome.missing
    end

    test 'credit_sum は指定区分以外の単位を数えない' do
      count('st_1')

      outcome = rule_health.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert_equal BigDecimal('0'), outcome.counted
    end

    test 'credit_sum は参照する区分に未確定があれば review' do
      @ledger.mark_uncertain('category' => 'health')

      outcome = rule_health.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
    end

    test 'credit_sum は参照しない区分の未確定を無視する' do
      @ledger.mark_uncertain('category' => 'basic')

      assert_not rule_health.evaluate(@catalogue, @ledger).review
    end

    test 'all_required は未修得の必修名を missing に入れる' do
      count('required_a')

      outcome = all_required.evaluate(@catalogue, @ledger)

      assert_equal ['人工科目 required_b'], outcome.missing
      assert_not_predicate outcome, :satisfied
      assert_not outcome.review
      assert_equal BigDecimal('2'), outcome.counted
    end

    test 'all_required は全必修を修得すれば充足' do
      count('required_a')
      count('required_b')

      outcome = all_required.evaluate(@catalogue, @ledger)

      assert outcome.satisfied
      assert_empty outcome.missing
    end

    test 'all_required は科目表の必修数が expected_course_count と違えば review' do
      count('required_a')
      count('required_b')

      outcome = all_required('expected_course_count' => 99).evaluate(@catalogue, @ledger)

      assert outcome.review
      assert_not_predicate outcome, :satisfied
    end

    test 'all_required は科目表の必修単位合計が required_credits と違えば review' do
      count('required_a')
      count('required_b')

      outcome = all_required('required_credits' => 99).evaluate(@catalogue, @ledger)

      assert outcome.review
      assert_not_predicate outcome, :satisfied
    end

    test 'all_required は未確定の必修があれば review' do
      count('required_a')
      @ledger.mark_uncertain(@catalogue.find('required_b'))

      assert all_required.evaluate(@catalogue, @ledger).review
    end

    test 'all_required は科目を特定できない入力があれば review' do
      @ledger.unknown_identity = true

      assert all_required.evaluate(@catalogue, @ledger).review
    end

    test 'one_of_paths は1つの経路を丸ごと満たせば充足' do
      count('st_1')
      count('st_2')

      outcome = calculus.evaluate(@catalogue, @ledger)

      assert outcome.satisfied
      assert_empty outcome.missing
      assert_nil outcome.counted
    end

    test 'one_of_paths は経路の一部だけでは充足しない' do
      count('st_1')

      outcome = calculus.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert_equal ['人工科目 st_2', '人工科目 intro_1', '人工科目 intro_2'], outcome.missing
    end

    test 'one_of_paths は科目表に候補のない役割があれば review' do
      outcome = rule('type' => 'one_of_paths', 'id' => 'x', 'label' => 'X', 'paths' => [['nobody']])
                .evaluate(@catalogue, @ledger)

      assert outcome.review
      assert_equal ['指定科目（nobody：科目表未確認）'], outcome.missing
    end

    test 'one_of_paths#reconcile は2つの経路が混ざっていたら全部を要確認にする' do
      %w[st_1 st_2 intro_1 intro_2].each { |key| count(key) }

      calculus.reconcile(@catalogue, @ledger)

      assert_equal BigDecimal('0'), @ledger.items['st_1'].counted
      assert_not_empty @ledger.notes
      outcome = calculus.evaluate(@catalogue, @ledger)
      assert_not_predicate outcome, :satisfied
      assert outcome.review
    end

    test 'one_of_paths#reconcile は定義の review_note をそのまま理由に使う' do
      %w[st_1 st_2 intro_1 intro_2].each { |key| count(key) }
      note = '微分積分学の系列が混在・重複しており、組合せと重複算入の確認が必要'

      calculus('review_note' => note).reconcile(@catalogue, @ledger)

      assert_includes @ledger.notes, "人工科目 st_1：#{note}"
      assert_equal BigDecimal('0'), @ledger.items['st_1'].counted
    end

    test 'one_of_paths#reconcile は review_note がなくても全部を要確認にする' do
      %w[st_1 st_2 intro_1 intro_2].each { |key| count(key) }

      calculus.reconcile(@catalogue, @ledger)

      %w[st_1 st_2 intro_1 intro_2].each { |key| assert_equal BigDecimal('0'), @ledger.items[key].counted }
      assert_includes @ledger.notes, '人工科目 st_1：微分積分の選択が重複しており、確認が必要'
      assert calculus.evaluate(@catalogue, @ledger).review
    end

    test 'one_of_paths は reconcile を呼ばなくても、経路が混ざっていれば充足にしない' do
      %w[st_1 st_2 intro_1 intro_2].each { |key| count(key) }

      outcome = calculus.evaluate(@catalogue, @ledger)

      assert_not outcome.satisfied
      assert outcome.review
    end

    test 'one_of_paths#reconcile は1つの経路だけなら何もしない' do
      count('st_1')
      count('st_2')

      calculus.reconcile(@catalogue, @ledger)

      assert_equal BigDecimal('2'), @ledger.items['st_1'].counted
      assert_empty @ledger.notes
    end

    test 'reconcile は credit_sum と all_required では何もしない' do
      count('health_1')

      rule_health.reconcile(@catalogue, @ledger)
      all_required.reconcile(@catalogue, @ledger)

      assert_equal BigDecimal('2'), @ledger.items['health_1'].counted
      assert_empty @ledger.notes
    end

    test 'check は id・label・required_credits・source を持つ Check を返す' do
      count('health_1')

      check = rule_health.check(@catalogue, @ledger)

      assert_equal 'health', check.id
      assert_equal '健康運動系', check.label
      assert_equal :satisfied, check.status
      assert_equal BigDecimal('2'), check.counted_credits
      assert_equal 2, check.required_credits
      assert_equal 'テスト便覧p1', check.source
      assert_empty check.missing_courses
    end

    test 'credit_sum の detail は充足なら算入と必要単位だけを述べる' do
      count('health_1')

      assert_equal '健康運動の説明。 確認済み算入2.0／必要2単位。',
                   rule_health.check(@catalogue, @ledger).detail
    end

    test 'credit_sum の detail は不足なら不足単位を足す' do
      check = rule_health('required_credits' => 3).check(@catalogue, @ledger)

      assert_equal :unmet, check.status
      assert_equal '健康運動の説明。 確認済み算入0.0／必要3単位。不足3.0単位。', check.detail
    end

    test 'credit_sum の detail は未確認なら不足を確定できないと述べる' do
      @ledger.mark_uncertain('category' => 'health')

      check = rule_health.check(@catalogue, @ledger)

      assert_equal :needs_review, check.status
      assert_equal '健康運動の説明。 確認済み算入0.0／必要2単位。未確認事項により不足の確定はできません。',
                   check.detail
    end

    test 'credit_sum の detail は説明がなくても余計な空白を残さない' do
      count('health_1')

      check = rule_health('detail' => nil).check(@catalogue, @ledger)

      assert_equal '確認済み算入2.0／必要2単位。', check.detail
    end

    test 'all_required の check は不足科目と確認済み科目数を述べる' do
      count('required_a')

      check = all_required.check(@catalogue, @ledger)

      assert_equal :unmet, check.status
      assert_equal ['人工科目 required_b'], check.missing_courses
      assert_equal 4, check.required_credits
      assert_equal '2科目それぞれの修得を確認。科目表の必修2科目中1科目を確認。余剰単位による代用は不可。', check.detail
    end

    test 'one_of_paths の check は各経路を「または」でつないで述べる' do
      check = calculus.check(@catalogue, @ledger)

      assert_equal :unmet, check.status
      assert_nil check.counted_credits
      assert_nil check.required_credits
      assert_equal '人工科目 st_1 ＋ 人工科目 st_2 または 人工科目 intro_1 ＋ 人工科目 intro_2', check.detail
      assert_equal 'テスト便覧p3', check.source
    end

    private

    def course(key, category, credits, roles: [], required: false)
      { 'key' => key, 'name' => "人工科目 #{key}", 'category' => category, 'credits' => credits,
        'required' => required, 'roles' => roles }
    end

    # 科目を算入済みとして ledger に載せる。
    def count(key)
      course = @catalogue.find(key)
      @ledger.add(course, BigDecimal(course['credits'].to_s)).counted = BigDecimal(course['credits'].to_s)
    end

    def rule(definition)
      Rules.condition(definition)
    end

    def rule_health(overrides = {})
      rule({ 'type' => 'credit_sum', 'id' => 'health', 'label' => '健康運動系', 'categories' => ['health'],
             'required_credits' => 2, 'detail' => '健康運動の説明。', 'source_page' => 'テスト便覧p1' }
           .merge(overrides))
    end

    def all_required(overrides = {})
      rule({ 'type' => 'all_required', 'id' => 'required_all', 'label' => '必修', 'expected_course_count' => 2,
             'required_credits' => 4, 'detail' => '余剰単位による代用は不可。', 'source_page' => 'テスト便覧p2' }
           .merge(overrides))
    end

    def calculus(overrides = {})
      rule({ 'type' => 'one_of_paths', 'id' => 'calculus', 'label' => '微分積分',
             'paths' => [%w[st_1 st_2], %w[intro_1 intro_2]], 'source_page' => 'テスト便覧p3' }.merge(overrides))
    end
  end
end

