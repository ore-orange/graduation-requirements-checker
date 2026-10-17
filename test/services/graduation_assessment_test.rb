# frozen_string_literal: true

require 'test_helper'
require 'bigdecimal'

class GraduationAssessmentTest < ActiveSupport::TestCase
  ALTERNATIVE_KEYS = %w[intro_i intro_ii intro_physics].freeze

  setup do
    # 人工の科目名・キーで、科目表の転記と便覧の計算規則を切り離す。
    # 単位配分は各要件の境界値に合わせる。
    @courses = []
    @requirements = {
      'english_roles' => %w[university_english intermediate_reading],
      'japanese_role' => 'japanese_expression',
      'calculus_paths' => [%w[st_i st_ii], %w[intro_i intro_ii]],
      'physics_roles' => %w[physics_i introductory_physics_i]
    }
    add('health', 'health', 2)
    add('humanities', 'humanities', 6)
    add('social', 'social', 4)
    add('integrated', 'integrated', 2)
    add('natural', 'natural', 2)
    add('japanese', 'japanese', 2, roles: ['japanese_expression'])
    add('english_university', 'english', 2, roles: ['university_english'])
    add('english_reading', 'english', 2, roles: ['intermediate_reading'])
    add('english_other', 'english', 8)
    add('st_i', 'basic', 2, roles: ['st_i'])
    add('st_ii', 'basic', 2, roles: ['st_ii'])
    add('physics', 'basic', 2, roles: ['physics_i'])
    add('intro_i', 'basic', 2, roles: ['intro_i'])
    add('intro_ii', 'basic', 2, roles: ['intro_ii'])
    add('intro_physics', 'basic', 2, roles: ['introductory_physics_i'])
    {
      'required_information' => [1, 1],
      'required_comprehensive' => [2, 1, 2, 2],
      'required_research' => [1, 1, 1, 1, 2, 2, 3, 3, 1, 1],
      'required_math' => [2, 2, 2],
      'required_core' => [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 4]
    }.each do |category, values|
      values.each_with_index { |credits, index| add("#{category}_#{index}", category, credits, required: true) }
    end
    add('elective_math', 'elective_math', 4)
    add('advanced', 'advanced', 10)
    add('technical_english', 'related', 8)
    add('fusion', 'fusion', 4, provider: 'mechanical')
    add('free', 'free', 11)
    @completed = @courses.reject { |course| ALTERNATIVE_KEYS.include?(course['key']) }
                         .map { |course| entry(course['key']) }
  end

  test 'a complete 130 credit selection satisfies all handbook checks' do
    snapshot = assess.actual

    assert_equal :satisfied, snapshot.status
    assert_equal 130, snapshot.counted_credits
    assert(snapshot.checks.all? { |rule| rule.status == :satisfied })
    assert_empty snapshot.review_notes
  end

  test 'registered and explicit plans affect projected only and are never inferred' do
    research = %w[required_research_6 required_research_7 required_research_8 required_research_9]
    @completed.reject! { |row| research.include?(row[:key]) }
    no_plan = assess
    assert_equal 122, no_plan.actual.counted_credits
    assert_equal no_plan.actual.counted_credits, no_plan.projected.counted_credits
    assert_equal :unmet, check(no_plan.projected, 'required_all').status

    result = assess(registered: research.first(2).map { |key| entry(key) },
                    planned: research.last(2).map { |key| entry(key) })
    assert_equal :unmet, result.actual.status
    assert_equal :satisfied, result.projected.status
    assert_equal 130, result.projected.counted_credits
    assert_equal 4, check(result.actual, 'required_all').missing_courses.length
  end

  test 'natural excess is capped in subtotal and final total and explained per course' do
    add('natural_extra', 'natural', 7)
    @completed << entry('natural_extra')
    snapshot = assess.actual

    assert_equal 130, snapshot.counted_credits
    assert_equal 14, check(snapshot, 'general_subtotal').counted_credits
    assert_equal 2, snapshot.course_results.select { |course| course.key.start_with?('natural') }.sum(&:counted_credits)
  end

  test 'natural credits cannot replace the twelve credit range excluding natural' do
    replace_credit('humanities', 4)
    replace_credit('natural', 6)
    snapshot = assess.actual

    assert_equal :unmet, check(snapshot, 'general_without_natural').status
    assert_equal 10, check(snapshot, 'general_without_natural').counted_credits
    assert_equal :unmet, check(snapshot, 'general_subtotal').status
    assert_equal 128, snapshot.counted_credits
  end

  test 'natural is not mandatory when the other general subjects provide fourteen' do
    @completed.reject! { |row| row[:key] == 'natural' }
    replace_credit('humanities', 8)

    assert_equal :satisfied, assess.actual.status
  end

  test 'health does not fill the fourteen credit general subtotal' do
    replace_credit('humanities', 4)
    replace_credit('health', 4)

    snapshot = assess.actual
    assert_equal 130, snapshot.counted_credits
    assert_equal :unmet, check(snapshot, 'general_subtotal').status
  end

  test 'integrated career and regional are a combined two credit requirement' do
    @completed.reject! { |row| row[:key] == 'integrated' }
    add('career', 'career', 1)
    add('regional', 'regional', 1)
    @completed.push(entry('career'), entry('regional'))

    assert_equal :satisfied, assess.actual.status
  end

  test 'specialist required courses cannot be replaced by surplus credits in their own group' do
    @completed.reject! { |row| row[:key] == 'required_core_0' }
    add('extra_core', 'required_core', 2)
    @completed << entry('extra_core')
    snapshot = assess.actual

    assert_equal 130, snapshot.counted_credits
    assert_equal :satisfied, check(snapshot, 'required_core').status
    assert_equal :unmet, check(snapshot, 'required_all').status
    assert_includes check(snapshot, 'required_all').missing_courses, '人工科目 required_core_0'
  end

  test 'partial required earned credits retain actual value but do not establish acquisition' do
    replace_credit('required_core_0', 1)
    replace_credit('free', 12)
    snapshot = assess.actual

    assert_equal 130, snapshot.counted_credits
    assert_equal 25, check(snapshot, 'required_core').counted_credits
    assert_equal :needs_review, check(snapshot, 'required_all').status
    assert_equal :unmet, check(snapshot, 'required_core').status
    assert_equal :needs_review, snapshot.status
  end

  test 'pending required grades never masquerade as completed acquisition' do
    replace_credit('required_core_0', nil)
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'required_all').status
    assert_equal :needs_review, check(snapshot, 'required_core').status
    assert_equal 0, course(snapshot, 'required_core_0').counted_credits
    assert_includes check(snapshot, 'required_all').missing_courses, '人工科目 required_core_0'
  end

  test 'zero credits for required course require review despite all keys being present' do
    replace_credit('required_information_0', 0)

    assert_equal :needs_review, check(assess.actual, 'required_all').status
  end

  test 'the twenty two inner credits include elective math advanced and related only' do
    assert_equal 22, check(assess.actual, 'elective_inner').counted_credits
    replace_credit('advanced', 8)
    replace_credit('free', 13)
    snapshot = assess.actual

    assert_equal 37, check(snapshot, 'elective_total').counted_credits
    assert_equal :unmet, check(snapshot, 'elective_inner').status
    assert_equal 20, check(snapshot, 'elective_inner').counted_credits
    assert_equal :unmet, snapshot.status
  end

  test 'fusion credits need four from one provider but additional providers may count' do
    replace_credit('fusion', 2)
    add('fusion_electrical', 'fusion', 2, provider: 'electrical')
    @completed << entry('fusion_electrical')
    split = assess.actual
    assert_equal 130, split.counted_credits
    assert_equal :unmet, check(split, 'fusion_provider').status
    assert_equal 2, check(split, 'fusion_provider').counted_credits

    replace_credit('fusion', 4)
    assert_equal :satisfied, assess.actual.status
    assert_equal 132, assess.actual.counted_credits
  end

  test 'own provider fusion is explicitly excluded from every aggregate' do
    add('own_fusion', 'fusion', 4, provider: 'intelligent_informatics')
    @completed << entry('own_fusion')
    snapshot = assess.actual

    assert_equal 130, snapshot.counted_credits
    assert_equal 0, course(snapshot, 'own_fusion').counted_credits
    assert_equal :satisfied, snapshot.status
  end

  test 'unknown fusion provider preserves known credits but cannot establish same provider rule' do
    @courses.find { |row| row['key'] == 'fusion' }['provider'] = nil
    snapshot = assess.actual

    assert_equal 130, snapshot.counted_credits
    assert_equal :satisfied, check(snapshot, 'elective_total').status
    assert_equal :needs_review, check(snapshot, 'fusion_provider').status
    assert_equal :needs_review, snapshot.status
  end

  test 'english eight plus one foreign language four is valid' do
    replace_credit('english_other', 4)
    add('german', 'foreign_language', 4, language: 'german')
    @completed << entry('german')

    assert_equal :satisfied, assess.actual.status
    assert_equal 8, check(assess.actual, 'foreign_language').counted_credits
  end

  test 'foreign credits cannot be combined across languages' do
    replace_credit('english_other', 4)
    add('german', 'foreign_language', 2, language: 'german')
    add('chinese', 'foreign_language', 2, language: 'chinese')
    @completed.push(entry('german'), entry('chinese'))

    assert_equal 130, assess.actual.counted_credits
    assert_equal :unmet, check(assess.actual, 'foreign_language').status
  end

  test 'unknown foreign language is review not an arbitrary shared language bucket' do
    replace_credit('english_other', 4)
    add('unknown_language', 'foreign_language', 4)
    @completed << entry('unknown_language')
    snapshot = assess.actual

    assert_equal :needs_review, check(snapshot, 'foreign_language').status
    assert_equal 130, snapshot.counted_credits
    assert_equal :needs_review, snapshot.status
  end

  test 'twelve english credits never replace the two specified english roles' do
    @completed.reject! { |row| row[:key] == 'english_reading' }
    replace_credit('english_other', 10)
    snapshot = assess.actual

    assert_equal :satisfied, check(snapshot, 'foreign_language').status
    assert_equal :unmet, check(snapshot, 'english_required').status
    assert_includes check(snapshot, 'english_required').missing_courses, '人工科目 english_reading'
  end

  test 'technical english remains related and cannot fill common english' do
    replace_credit('english_other', 6)
    replace_credit('technical_english', 10)
    snapshot = assess.actual

    assert_equal 130, snapshot.counted_credits
    assert_equal :unmet, check(snapshot, 'foreign_language').status
    assert_equal 24, check(snapshot, 'elective_inner').counted_credits
  end

  test 'arbitrary basic credits cannot replace specified calculus and physics' do
    @completed.reject! { |row| %w[st_i st_ii physics].include?(row[:key]) }
    add('arbitrary_basic', 'basic', 6)
    @completed << entry('arbitrary_basic')
    snapshot = assess.actual

    assert_equal :satisfied, check(snapshot, 'basic_total').status
    assert_equal :unmet, check(snapshot, 'calculus').status
    assert_equal :unmet, check(snapshot, 'physics').status
  end

  test 'introductory calculus and physics alternatives form a complete valid pathway' do
    @completed.reject! { |row| %w[st_i st_ii physics].include?(row[:key]) }
    @completed.concat(%w[intro_i intro_ii intro_physics].map { |key| entry(key) })

    assert_equal :satisfied, assess.actual.status
  end

  test 'mixed calculus pathways are review and are not definitively rejected as unmet' do
    @completed.reject! { |row| row[:key] == 'st_ii' }
    @completed << entry('intro_ii')
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'calculus').status
    assert_equal :needs_review, check(snapshot, 'basic_total').status
    assert_equal 0, course(snapshot, 'st_i').counted_credits
    assert_equal 0, course(snapshot, 'intro_ii').counted_credits
  end

  test 'complete calculus pathway plus overlapping alternative also requires review' do
    @completed << entry('intro_i')

    assert_equal :needs_review, check(assess.actual, 'calculus').status
    assert_equal :needs_review, assess.actual.status
  end

  test 'both physics alternatives are not silently counted or arbitrarily chosen' do
    @completed << entry('intro_physics')
    snapshot = assess.actual

    assert_equal :needs_review, check(snapshot, 'physics').status
    assert_equal 0, course(snapshot, 'physics').counted_credits
    assert_equal 0, course(snapshot, 'intro_physics').counted_credits
    assert_equal :satisfied, check(snapshot, 'calculus').status
  end

  test 'same canonical key in history current and plan counts exactly once' do
    @completed << entry('advanced')
    result = assess(registered: [entry('advanced')], planned: [entry('advanced')])

    assert_equal :satisfied, result.projected.status
    assert_equal 130, result.projected.counted_credits
    assert_equal(1, result.projected.course_results.count { |row| row.key == 'advanced' })
  end

  test 'earned credit amount wins over a pending retake nominal amount' do
    replace_credit('advanced', 8)
    result = assess(registered: [entry('advanced')], planned: [entry('advanced')])

    assert_equal 128, result.actual.counted_credits
    assert_equal 128, result.projected.counted_credits
    assert_equal :unmet, check(result.projected, 'elective_inner').status
    assert_empty result.projected.review_notes
  end

  test 'conflicting successful retakes are review not latest maximum or sum' do
    @completed << entry('advanced', credits: 8)
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'elective_inner').status
    assert_equal 0, course(snapshot, 'advanced').counted_credits
    assert_nil course(snapshot, 'advanced').credits
  end

  test 'missing credit on one successful duplicate is not silently discarded' do
    @completed << entry('required_core_0', credits: nil)

    assert_equal :needs_review, check(assess.actual, 'required_all').status
  end

  test 'course number or display name is never treated as a canonical alias' do
    @completed.reject! { |row| row[:key] == 'required_core_0' }
    @completed << { key: '工共114', name: '人工科目 required_core_0', credits: 2 }
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'required_all').status
    assert_equal 0, course(snapshot, '工共114').counted_credits
    assert_includes check(snapshot, 'required_all').missing_courses, '人工科目 required_core_0'
  end

  test 'unmapped nil key is visible and prevents falsely definitive deficits' do
    @completed << { key: nil, name: '未対応の科目', credits: 2 }
    replace_credit('health', 1)
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'health').status
    assert_equal :satisfied, check(snapshot, 'required_all').status
  end

  test 'explicitly excluded courses neither count nor trigger review for missing credits' do
    add('information_science_exercise', 'excluded', nil)
    @completed << entry('information_science_exercise')
    snapshot = assess.actual

    assert_equal :satisfied, snapshot.status
    assert_equal 130, snapshot.counted_credits
    assert_equal 0, course(snapshot, 'information_science_exercise').counted_credits
  end

  test 'approval must be explicit and is per entry not inferred from course selection' do
    @courses.find { |row| row['key'] == 'free' }['requires_approval'] = true
    assert_equal :needs_review, assess.actual.status
    assert_equal 0, course(assess.actual, 'free').counted_credits

    @completed.find { |row| row[:key] == 'free' }[:approved] = false
    assert_equal :unmet, assess.actual.status
    assert_empty assess.actual.review_notes

    @completed.find { |row| row[:key] == 'free' }[:approved] = true
    assert_equal :satisfied, assess.actual.status
  end

  test 'conflicting approval records are not resolved by choosing the approved duplicate' do
    @courses.find { |row| row['key'] == 'free' }['requires_approval'] = true
    @completed.find { |row| row[:key] == 'free' }[:approved] = true
    @completed << entry('free').merge(approved: false)

    assert_equal :needs_review, assess.actual.status
    assert_equal 0, course(assess.actual, 'free').counted_credits
  end

  test 'unknown required course catalogue metadata prevents a false pass' do
    @courses.find { |row| row['key'] == 'required_core_0' }['required'] = false
    snapshot = assess.actual

    assert_equal :needs_review, check(snapshot, 'required_all').status
    assert_equal :needs_review, snapshot.status
  end

  test 'absent designated role metadata is review rather than definitive missing course' do
    @courses.find { |row| row['key'] == 'japanese' }['roles'] = []

    assert_equal :needs_review, check(assess.actual, 'japanese').status
  end

  test 'unknown credits and source review reasons do not fabricate nominal counts' do
    @courses.find { |row| row['key'] == 'advanced' }['review_reason'] = '一次資料の単位欄が未確認'
    replace_credit('advanced', nil)
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'elective_inner').status
    assert_equal :satisfied, check(snapshot, 'english_required').status
    assert_nil course(snapshot, 'advanced').credits
    assert_equal 0, course(snapshot, 'advanced').counted_credits
  end

  test 'unknown enrollment status affects both snapshots without counting assumed credits' do
    @completed.reject! { |row| row[:key] == 'required_core_0' }
    result = assess(unresolved: [entry('required_core_0').merge(reason: '過去の履修状態が未確認')])

    [result.actual, result.projected].each do |snapshot|
      assert_equal :needs_review, snapshot.status
      assert_equal 128, snapshot.counted_credits
      assert_equal :needs_review, check(snapshot, 'required_all').status
      assert_equal :satisfied, check(snapshot, 'health').status
    end
  end

  test 'decimal credits sum deterministically at the exact boundary' do
    @completed.reject! { |row| row[:key] == 'free' }
    110.times do |index|
      add("fraction_#{index}", 'free', 0.1)
      @completed << entry("fraction_#{index}")
    end
    snapshot = assess.actual

    assert_equal BigDecimal('130'), snapshot.counted_credits
    assert_equal BigDecimal('37'), check(snapshot, 'elective_total').counted_credits
    assert_equal :satisfied, snapshot.status
    @completed.pop
    assert_equal BigDecimal('129.9'), assess.actual.counted_credits
    assert_equal :unmet, assess.actual.status
  end

  test 'invalid negative and nonfinite credits require review instead of reducing totals' do
    [-1, Float::NAN, Float::INFINITY, '11'].each do |credits|
      replace_credit('free', credits)
      snapshot = assess.actual
      assert_equal :needs_review, snapshot.status
      assert_equal 119, snapshot.counted_credits
      assert_equal 0, course(snapshot, 'free').counted_credits
    end
  end

  test 'assessment leaves caller hashes and entries untouched and can be reused' do
    curriculum = document
    original = Marshal.dump([curriculum, @completed])
    evaluator = GraduationAssessment.new(curriculum: curriculum)
    first = evaluator.call(completed: @completed)
    second = evaluator.call(completed: [])

    assert_equal :satisfied, first.actual.status
    assert_equal :unmet, second.actual.status
    assert_equal original, Marshal.dump([curriculum, @completed])
  end

  test 'an unknown category is not silently treated as free elective credit' do
    @courses.find { |row| row['key'] == 'free' }['category'] = 'unverified'
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal 119, snapshot.counted_credits
    assert_equal :needs_review, check(snapshot, 'elective_total').status
    assert_equal 0, course(snapshot, 'free').counted_credits
  end

  test 'missing source references withhold affected credits and expose a review reason' do
    @courses.find { |row| row['key'] == 'advanced' }['source'] = nil
    snapshot = assess.actual

    assert_equal :needs_review, snapshot.status
    assert_equal :needs_review, check(snapshot, 'elective_inner').status
    assert_equal 0, course(snapshot, 'advanced').counted_credits
  end

  test 'unearned specified english cannot satisfy its role even if other english reaches twelve' do
    replace_credit('english_university', nil)
    replace_credit('english_other', 10)
    snapshot = assess.actual

    assert_equal :satisfied, check(snapshot, 'foreign_language').status
    assert_equal :needs_review, check(snapshot, 'english_required').status
    assert_includes check(snapshot, 'english_required').missing_courses, '人工科目 english_university'
  end

  test 'future approval dependent courses remain review until approval is actually known' do
    @courses.find { |row| row['key'] == 'free' }['requires_approval'] = true
    @completed.reject! { |row| row[:key] == 'free' }
    result = assess(planned: [entry('free')])

    assert_equal :unmet, result.actual.status
    assert_equal :needs_review, result.projected.status
    assert_equal 119, result.projected.counted_credits
  end

  test 'unknown enrollment of definitively excluded courses cannot change satisfied snapshots' do
    add('information_science_exercise', 'excluded', nil)
    add('own_fusion', 'fusion', 4, provider: 'intelligent_informatics')
    result = assess(unresolved: [entry('information_science_exercise'), entry('own_fusion')])

    [result.actual, result.projected].each do |snapshot|
      assert_equal :satisfied, snapshot.status
      assert_equal 130, snapshot.counted_credits
      assert_empty snapshot.review_notes
      assert_equal 0, course(snapshot, 'information_science_exercise').counted_credits
      assert_equal 0, course(snapshot, 'own_fusion').counted_credits
    end
  end

  private

  def add(key, category, credits, required: false, roles: [], provider: nil, language: nil)
    @courses << {
      'key' => key, 'name' => "人工科目 #{key}", 'number' => nil, 'category' => category,
      'credits' => credits, 'required' => required, 'roles' => roles, 'provider' => provider,
      'language' => language, 'requires_approval' => false, 'review_reason' => nil,
      'source' => 'artificial-test-fixture', 'source_page' => 'テスト専用', 'selectable' => true
    }
  end

  def entry(key, credits: :catalogue)
    course = @courses.find { |row| row['key'] == key }
    { key: key, credits: credits == :catalogue ? course.fetch('credits') : credits, approved: nil }
  end

  def replace_credit(key, credits)
    @completed.find { |row| row[:key] == key }[:credits] = credits
  end

  def document
    { 'courses' => @courses, 'requirements' => @requirements }
  end

  def assess(**)
    GraduationAssessment.new(curriculum: document).call(completed: @completed, **)
  end

  def check(snapshot, id)
    snapshot.checks.find { |rule| rule.id == id } || flunk("missing check #{id}")
  end

  def course(snapshot, key)
    snapshot.course_results.find { |row| row.key == key } || flunk("missing course #{key}")
  end
end

