# frozen_string_literal: true

require 'test_helper'

class GraduationAssessment
  class RulesCompositeTest < ActiveSupport::TestCase
    setup do
      # 人工の科目で、手書きの定義だけを評価する。実際の便覧は読み込まない。
      @courses = [
        course('kikai_991', 'fusion', 2, number: '機械991'),
        course('kikai_992', 'fusion', 2, number: '機械992'),
        course('shaki_991', 'fusion', 2, number: '社基991'),
        course('unreadable', 'fusion', 2, number: nil),
        course('en_1', 'english', 4, number: '外101'),
        course('en_2', 'english', 4, number: '外102'),
        course('en_3', 'english', 4, number: '外103'),
        course('de_1', 'foreign_language', 2, number: '外201', language: 'german'),
        course('de_2', 'foreign_language', 2, number: '外202', language: 'german'),
        course('fr_1', 'foreign_language', 2, number: '外301', language: 'french'),
        course('id_1', 'foreign_language', 2, number: '外701', language: 'indonesian'),
        course('th_1', 'foreign_language', 2, number: '外702', language: 'thai'),
        course('fl_unreadable', 'foreign_language', 2, number: 'ドイツ語')
      ]
      @catalogue = Catalogue.new('courses' => @courses, 'requirements' => {})
      @ledger = Ledger.new(@catalogue)
    end

    test 'condition は grouped_max・any_of の型を返す' do
      assert_instance_of Rules::GroupedMax, grouped_max('number_prefix', 4)
      assert_instance_of Rules::AnyOf, foreign_language_rule
    end

    test '空の all_of は充足にせず review にする' do
      outcome = Rules::AllOf.new('type' => 'all_of', 'conditions' => []).evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
      assert_equal BigDecimal('0'), outcome.counted
      assert(@ledger.notes.any? { |note| note.include?('conditions') })
    end

    test '空の all_of を any_of の選択肢にしても any_of を充足にしない' do
      rule = any_of([{ 'type' => 'all_of', 'conditions' => [] }])

      assert_equal :needs_review, rule_status(rule)
    end

    test '空の any_of は不足と断定せず review にする' do
      rule = any_of([])

      outcome = rule.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
      assert_equal BigDecimal('0'), outcome.counted
      assert_equal :needs_review, rule.check(@catalogue, @ledger).status
      assert(@ledger.notes.any? { |note| note.include?('options') })
    end

    test '単独の all_of は構築せず Unknown にして、充足にしない' do
      count('en_1', 'en_2')
      rule = Rules.condition('type' => 'all_of', 'id' => 'solo', 'label' => '単独',
                             'conditions' => [english_sum_definition(8)])

      assert_instance_of Rules::Unknown, rule
      outcome = rule.evaluate(@catalogue, @ledger)
      assert_not_predicate outcome, :satisfied
      assert outcome.review
      assert_equal 'solo', rule.check(@catalogue, @ledger).id
    end

    test 'grouped_max は最大のグループの単位を数える' do
      count('kikai_991', 'kikai_992', 'shaki_991')

      outcome = grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('4'), outcome.counted
      assert outcome.satisfied
      assert_not outcome.review
    end

    test 'grouped_max はグループを合算しない' do
      count('kikai_991', 'shaki_991')

      outcome = grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('2'), outcome.counted
      assert_not_predicate outcome, :satisfied
    end

    test 'grouped_max は算入していない科目を数えない' do
      count('kikai_991')

      assert_equal BigDecimal('2'), grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger).counted
    end

    test 'grouped_max は指定区分以外の科目を数えない' do
      count('kikai_991', 'en_1')

      assert_equal BigDecimal('2'), grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger).counted
    end

    test 'grouped_max は number_prefix_hundreds で接頭辞と百の位ごとに分ける' do
      count('de_1', 'de_2', 'fr_1')

      outcome = grouped_max('number_prefix_hundreds', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('4'), outcome.counted
      assert outcome.satisfied
    end

    test 'grouped_max は field:language で言語ごとに分ける' do
      count('de_1', 'de_2', 'fr_1')

      outcome = grouped_max('field:language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('4'), outcome.counted
      assert outcome.satisfied
      assert_not outcome.review
    end

    test 'grouped_max は field:language で2つの言語を合算しない' do
      count('de_1', 'fr_1')

      outcome = grouped_max('field:language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('2'), outcome.counted
      assert_not_predicate outcome, :satisfied
    end

    test 'grouped_max は百の位が同じでも言語が違えば field:language では合算しない' do
      count('id_1', 'th_1')

      by_field = grouped_max('field:language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)
      by_hundreds = grouped_max('number_prefix_hundreds', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('2'), by_field.counted
      assert_not_predicate by_field, :satisfied
      assert_equal BigDecimal('4'), by_hundreds.counted
    end

    test 'grouped_max は language が空の科目が算入されていたら review' do
      count('de_1', 'de_2', 'fl_unreadable')

      outcome = grouped_max('field:language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)

      assert outcome.review
      assert_equal BigDecimal('4'), outcome.counted
    end

    test 'grouped_max は language が空でも算入単位が0なら review にしない' do
      count('de_1', 'de_2')
      @ledger.add(@catalogue.find('fl_unreadable'), BigDecimal('2'))

      assert_not grouped_max('field:language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger).review
    end

    test 'grouped_max は language が空白だけの科目も空として review にする' do
      @catalogue.find('de_1')['language'] = '  '
      count('de_1')

      assert grouped_max('field:language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger).review
    end

    test 'grouped_max は知らない group_by を黙って通さない' do
      count('de_1')

      assert_raises(KeyError) { grouped_max('language', 4, category: 'foreign_language').evaluate(@catalogue, @ledger) }
    end

    test 'grouped_max は number_prefix なら外国語を言語で分けない' do
      count('de_1', 'de_2', 'fr_1')

      outcome = grouped_max('number_prefix', 4, category: 'foreign_language').evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('6'), outcome.counted
    end

    test 'grouped_max は科目番号が読めない科目が算入されていたら review' do
      count('kikai_991', 'kikai_992', 'unreadable')

      outcome = grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger)

      assert outcome.review
      assert_equal BigDecimal('4'), outcome.counted
    end

    test 'grouped_max は算入単位が0の科目の番号が読めなくても review にしない' do
      count('kikai_991', 'kikai_992')
      @ledger.add(@catalogue.find('unreadable'), BigDecimal('2'))

      assert_not grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger).review
    end

    test 'grouped_max は区分に未確定があれば review' do
      count('kikai_991', 'kikai_992')
      @ledger.mark_uncertain('category' => 'fusion')

      assert grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger).review
    end

    test 'grouped_max は算入がなければ0単位で不足' do
      outcome = grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger)

      assert_equal BigDecimal('0'), outcome.counted
      assert_not_predicate outcome, :satisfied
    end

    test 'any_of は最初の選択肢を満たせば充足' do
      count('en_1', 'en_2', 'en_3')

      outcome = foreign_language_rule.evaluate(@catalogue, @ledger)

      assert outcome.satisfied
      assert_equal BigDecimal('12'), outcome.counted
    end

    test 'any_of はどれか1つ満たせば充足' do
      count('en_1', 'en_2', 'de_1', 'de_2')

      outcome = foreign_language_rule.evaluate(@catalogue, @ledger)

      assert outcome.satisfied
      assert_not outcome.review
    end

    test 'any_of はどれも満たさなければ不足' do
      count('en_1', 'en_2', 'de_1', 'fr_1')

      assert_not_predicate foreign_language_rule.evaluate(@catalogue, @ledger), :satisfied
    end

    test 'any_of の counted は最初の選択肢の値' do
      count('en_1', 'en_2', 'de_1', 'de_2')

      assert_equal BigDecimal('8'), foreign_language_rule.evaluate(@catalogue, @ledger).counted
    end

    test '外7xx の別々の言語を合わせて一外国語4単位とは数えない' do
      count('en_1', 'en_2', 'id_1', 'th_1')

      outcome = foreign_language_rule.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert_not outcome.review
    end

    test 'any_of はどれかの選択肢が review なら review' do
      count('en_1', 'en_2', 'fl_unreadable')

      outcome = foreign_language_rule.evaluate(@catalogue, @ledger)

      assert outcome.review
      assert_not_predicate outcome, :satisfied
    end

    test 'any_of は満たした選択肢があっても他の選択肢の review を伝える' do
      count('en_1', 'en_2', 'en_3', 'fl_unreadable')

      outcome = foreign_language_rule.evaluate(@catalogue, @ledger)

      assert outcome.satisfied
      assert outcome.review
    end

    test 'any_of は check で Check を作る' do
      count('en_1', 'en_2', 'de_1', 'fr_1')

      check = foreign_language_rule.check(@catalogue, @ledger)

      assert_equal 'foreign_language', check.id
      assert_equal :unmet, check.status
      assert_includes check.detail, '英語12単位'
    end

    test 'all_of は全部満たしたときだけ充足' do
      count('en_1', 'en_2', 'de_1', 'de_2')

      assert all_of([english_sum(8), grouped_max('field:language', 4, category: 'foreign_language')])
        .evaluate(@catalogue, @ledger).satisfied
      assert_not all_of([english_sum(12), english_sum(8)]).evaluate(@catalogue, @ledger).satisfied
    end

    test 'all_of はどれかが review なら review' do
      count('en_1', 'en_2', 'fl_unreadable')

      outcome = all_of([english_sum(8), grouped_max('field:language', 4, category: 'foreign_language')])
                .evaluate(@catalogue, @ledger)

      assert outcome.review
    end

    test 'any_of の中の any_of は中身が満たされていても、未知の型として扱い review にする' do
      count('en_1', 'en_2')
      nested = { 'type' => 'any_of', 'id' => 'inner', 'label' => '内側', 'options' => [english_sum_definition(8)] }
      rule = any_of([english_sum_definition(99), nested])

      outcome = rule.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
      assert(@ledger.notes.any? { |note| note.include?('any_of') })
    end

    test '置けない位置の既知の型は、解釈できないのではなく置けないと注記する' do
      any_of([{ 'type' => 'credit_sum', 'id' => 'x', 'categories' => [], 'required_credits' => 0 }, stray_any_of])
        .evaluate(@catalogue, @ledger)

      assert_equal ['inner：規則の型「any_of」はこの位置には置けません'], @ledger.notes
    end

    test '未知の型の注記は解釈できないと書き、置けないとは書かない' do
      unknown_rule.evaluate(@catalogue, @ledger)

      assert_equal ['gpa：規則の型「gpa」をこのアプリは解釈できません'], @ledger.notes
    end

    test '置けない位置の型は check の detail でも置けないと書く' do
      check = Rules.condition('type' => 'all_of', 'id' => 'solo', 'label' => '単独').check(@catalogue, @ledger)

      assert_includes check.detail, 'この位置には置けません'
    end

    test 'all_of の中の all_of は未知の型として扱い、充足にしない' do
      count('en_1', 'en_2')
      inner = { 'type' => 'all_of', 'conditions' => [english_sum_definition(8)] }
      rule = Rules::AllOf.new('type' => 'all_of', 'conditions' => [english_sum_definition(8), inner])

      outcome = rule.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
    end

    test 'all_of の中に any_of を置くと未知の型として扱う' do
      count('en_1', 'en_2')
      inner = { 'type' => 'any_of', 'options' => [english_sum_definition(8)] }

      assert_not_predicate Rules::AllOf.new('type' => 'all_of', 'conditions' => [inner]).evaluate(@catalogue, @ledger),
                           :satisfied
    end

    test 'any_of の中の許可されない型は未知の型として扱う' do
      count('en_1', 'en_2')
      stray = { 'type' => 'all_required', 'id' => 'stray', 'label' => '必修' }

      outcome = any_of([stray]).evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
    end

    test 'any_of の中の未知の型は他の選択肢が満たされなければ要確認になる' do
      count('en_1')
      rule = any_of([english_sum_definition(12), { 'type' => 'gpa', 'id' => 'gpa', 'label' => 'GPA' }])

      assert_equal :needs_review, rule_status(rule)
    end

    test 'any_of は入れ子の中身が Hash でなくても例外にせず review にする' do
      outcome = any_of([english_sum_definition(12), 'english']).evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
    end

    test '未知の型は充足にならず review になる' do
      outcome = unknown_rule.evaluate(@catalogue, @ledger)

      assert_not_predicate outcome, :satisfied
      assert outcome.review
      assert_equal BigDecimal('0'), outcome.counted
    end

    test '未知の型は理由を ledger の notes に残す' do
      unknown_rule.evaluate(@catalogue, @ledger)

      assert(@ledger.notes.any? { |note| note.include?('gpa') })
    end

    test 'condition は未知の type を例外にせず Unknown を返す' do
      assert_instance_of Rules::Unknown, unknown_rule
      assert_instance_of Rules::Unknown, Rules.condition({})
    end

    test '未知の型も check で要確認の Check を作る' do
      check = unknown_rule.check(@catalogue, @ledger)

      assert_equal 'gpa', check.id
      assert_equal 'GPA', check.label
      assert_equal :needs_review, check.status
      assert_empty check.missing_courses
    end

    test '未知の型は id・label が無くても check できる' do
      check = Rules.condition('type' => 'gpa').check(@catalogue, @ledger)

      assert_equal :needs_review, check.status
    end

    private

    def course(key, category, credits, number:, language: nil)
      { 'key' => key, 'name' => "人工科目 #{key}", 'category' => category, 'credits' => credits,
        'number' => number, 'language' => language, 'required' => false, 'roles' => [] }
    end

    def count(*keys)
      keys.each do |key|
        course = @catalogue.find(key)
        @ledger.add(course, BigDecimal(course['credits'].to_s)).counted = BigDecimal(course['credits'].to_s)
      end
    end

    def grouped_max(group_by, required, category: 'fusion')
      Rules.condition('type' => 'grouped_max', 'id' => 'g', 'label' => 'g', 'category' => category,
                      'group_by' => group_by, 'required_credits' => required)
    end

    def grouped_max_definition(group_by, required, category)
      { 'type' => 'grouped_max', 'category' => category, 'group_by' => group_by, 'required_credits' => required }
    end

    def english_sum_definition(required)
      { 'type' => 'credit_sum', 'categories' => ['english'], 'required_credits' => required }
    end

    def english_sum(required)
      Rules.condition(english_sum_definition(required))
    end

    def all_of(conditions)
      Rules::AllOf.new('type' => 'all_of', 'conditions' => conditions.map(&:definition))
    end

    def any_of(options)
      Rules.condition('type' => 'any_of', 'id' => 'a', 'label' => 'a', 'options' => options)
    end

    # 英語12単位、または英語8単位＋同じ一外国語4単位。
    def foreign_language_rule
      Rules.condition(
        'type' => 'any_of', 'id' => 'foreign_language', 'label' => '外国語の選択経路',
        'detail' => '英語12単位、または英語8単位＋同じ一外国語4単位。',
        'options' => [
          english_sum_definition(12),
          { 'type' => 'all_of', 'conditions' => [english_sum_definition(8),
                                                 grouped_max_definition('field:language', 4,
                                                                        'foreign_language')] }
        ]
      )
    end

    def stray_any_of
      { 'type' => 'any_of', 'id' => 'inner', 'label' => '内側', 'options' => [english_sum_definition(8)] }
    end

    def unknown_rule
      Rules.condition('type' => 'gpa', 'id' => 'gpa', 'label' => 'GPA')
    end

    def rule_status(rule)
      outcome = rule.evaluate(@catalogue, @ledger)
      Rules.status(outcome.satisfied, outcome.review)
    end
  end
end

