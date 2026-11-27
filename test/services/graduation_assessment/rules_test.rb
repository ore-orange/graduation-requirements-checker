# frozen_string_literal: true

require 'test_helper'

# 2024年度の便覧では起きない規則の扱い(知らない型・壊れた規則)を、小さな便覧で確かめる。
# 2024年度の判定結果そのものは golden_test が見張る。
class GraduationAssessmentRulesTest < ActiveSupport::TestCase
  COURSES = [
    { 'key' => 'a', 'name' => '科目A', 'credits' => 2, 'category' => 'general', 'language' => 'german',
      'source' => 'テスト', 'source_page' => 'テスト' },
    { 'key' => 'b', 'name' => '科目B', 'credits' => 2, 'category' => 'general', 'language' => nil,
      'source' => 'テスト', 'source_page' => 'テスト' }
  ].freeze
  CATEGORIES = [{ 'key' => 'general', 'label' => '一般' }].freeze

  def assess(rules, completed: %w[a b])
    document = { 'courses' => COURSES, 'categories' => CATEGORIES, 'rules' => rules }
    entries = completed.map { |key| { key: key, credits: 2, approved: nil, name: key } }
    GraduationAssessment.new(curriculum: document).call(completed: entries).actual
  end

  def credit_sum(id, required)
    { 'id' => id, 'type' => 'credit_sum', 'label' => id, 'categories' => ['general'], 'required_credits' => required }
  end

  test '知らない型の規則は、充足とは答えず要確認にする' do
    snapshot = assess([credit_sum('sum', 2), { 'id' => 'mystery', 'type' => 'magic' }])

    mystery = snapshot.checks.find { |check| check.id == 'mystery' }
    assert_equal :needs_review, mystery.status
    assert_match 'magic', mystery.detail
    assert_equal :needs_review, snapshot.status
  end

  test 'all_of は単独では置けず、要確認にする' do
    snapshot = assess([{ 'id' => 'alone', 'type' => 'all_of', 'conditions' => [credit_sum(nil, 2)] }])

    assert_equal :needs_review, snapshot.checks.first.status
  end

  test 'any_of の説明文に、入れ子の条件の値を差し込む。知らない名前はそのまま残す' do
    rule = { 'id' => 'any', 'type' => 'any_of', 'counted_from' => 'total',
             'detail' => '合計{{total}}単位、{{missing}}。', 'options' => [credit_sum('total', 4)] }

    check = assess([rule]).checks.first
    assert_equal :satisfied, check.status
    assert_equal BigDecimal('4'), check.counted_credits
    assert_equal '合計4.0単位、{{missing}}。', check.detail
  end

  test 'grouped_max は、グループを決められない科目を数えず、注記して要確認にする' do
    rule = { 'id' => 'one_language', 'type' => 'grouped_max', 'category' => 'general', 'group_by' => 'field:language',
             'required_credits' => 2, 'missing_group_note' => '言語が未確認' }

    snapshot = assess([rule])
    check = snapshot.checks.first
    assert_equal BigDecimal('2'), check.counted_credits
    assert_equal :satisfied, check.status
    assert_includes snapshot.review_notes, '科目B：言語が未確認'
    assert_equal :needs_review, snapshot.status
  end

  test 'exclude は、欄の値まで一致した科目だけを算入しない' do
    exclude = { 'type' => 'exclude', 'category' => 'general', 'field' => 'language', 'value' => 'german',
                'reason' => 'ドイツ語は数えない' }

    snapshot = assess([credit_sum('sum', 2), exclude])
    assert_equal BigDecimal('2'), snapshot.counted_credits
    assert_equal 'ドイツ語は数えない', snapshot.course_results.find { |result| result.key == 'a' }.reason
  end

  test 'cap は、キー順に配分して打ち切り、理由を残す' do
    cap = { 'type' => 'cap', 'category' => 'general', 'credits' => 3, 'reason' => '一般は3単位まで' }

    results = assess([credit_sum('sum', 2), cap]).course_results.index_by(&:key)
    assert_equal BigDecimal('2'), results['a'].counted_credits
    assert_equal BigDecimal('1'), results['b'].counted_credits
    assert_equal '一般は3単位まで（この科目は1.0単位を算入）', results['b'].reason
  end

  test '壊れた規則・条件の無い便覧は、読み込む時点で止める' do
    broken = [
      [{ 'type' => 'cap', 'category' => 'general', 'credits' => -1, 'reason' => 'x' }],
      [{ 'type' => 'exclude', 'category' => 'general', 'reason' => '' }],
      [{ 'id' => 'g', 'type' => 'grouped_max', 'category' => 'general', 'group_by' => 'number_prefix',
         'required_credits' => 2, 'missing_group_note' => 'x' }],
      [{ 'type' => 'cap', 'category' => 'general', 'credits' => 2, 'reason' => 'x' }]
    ]

    broken.each do |rules|
      assert_raises(ArgumentError, rules.inspect) { assess(rules) }
    end
  end
end

