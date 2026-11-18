# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  # 便覧に残す科目の絞り込み。科目番号から区分が決まる科目は、番号だけで引けるので便覧に残さない。
  # 人が触った科目・番号から決まらない科目・特別な扱いのある科目は、必ず残す。
  class CourseFilterTest < ActiveSupport::TestCase
    DOCUMENT = {
      'categories' => [
        { 'key' => 'humanities', 'label' => '人文系', 'number_patterns' => ['人'] },
        { 'key' => 'advanced', 'label' => '知能情報アドバンスト' }
      ]
    }.freeze

    def course(number, category, **fields)
      { 'key' => "course_#{number}", 'number' => number, 'name' => "科目#{number}", 'credits' => 2,
        'category' => category, 'required' => false, 'roles' => [], 'review_reason' => nil,
        'requires_approval' => false, 'selectable' => true }.merge(fields.stringify_keys)
    end

    def filter = CourseFilter.new(DOCUMENT)

    test '番号パターンで区分が決まり、読みも一致する科目は残さない' do
      assert_not filter.keep?(course('人01', 'humanities'))
    end

    test '番号パターンを持たない区分の科目は残す' do
      assert filter.keep?(course('知能301', 'advanced'))
    end

    test '科目番号が空の科目は残す' do
      assert filter.keep?(course(nil, 'humanities'))
    end

    test 'パターンが決めた区分と読みが違う科目は残す' do
      assert filter.keep?(course('人01', 'advanced'))
    end

    test '必修の科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', required: true))
    end

    test '役割を持つ科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', roles: ['x']))
    end

    test '承認が要る科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', requires_approval: true))
    end

    test '選べない科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', selectable: false))
    end

    test 'selectable の欄が無い科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities').except('selectable'))
    end

    test 'AIが要確認とした科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', review_reason: '単位が読めません'))
    end

    # grouped_max は区分の単位を欄の値ごとに分けて数える。欄の値は番号から決まらないので、外すと復元できない。
    def grouped_document(group_by, nest: false, categories: DOCUMENT['categories'])
      rule = { 'type' => 'grouped_max', 'id' => 'g', 'category' => 'humanities',
               'group_by' => group_by, 'required_credits' => 4 }
      rule = { 'type' => 'any_of', 'id' => 'a', 'options' => [{ 'type' => 'all_of', 'conditions' => [rule] }] } if nest
      { 'categories' => categories, 'rules' => [rule] }
    end

    test '規則が欄で分ける便覧では、その欄に値を持つ科目は、パターンで決まっても残す' do
      filter = CourseFilter.new(grouped_document('field:language'))

      assert filter.keep?(course('人01', 'humanities', language: 'german'))
    end

    test '入れ子の規則が欄で分けていても、その欄に値を持つ科目は残す' do
      filter = CourseFilter.new(grouped_document('field:language', nest: true))

      assert filter.keep?(course('人01', 'humanities', language: 'german'))
    end

    test '欄で分ける規則があっても、その欄に値が無い科目は残さない' do
      filter = CourseFilter.new(grouped_document('field:language'))

      assert_not filter.keep?(course('人01', 'humanities'))
      assert_not filter.keep?(course('人02', 'humanities', language: nil))
      assert_not filter.keep?(course('人03', 'humanities', language: ''))
    end

    test 'その欄で分ける規則が無い便覧では、欄に値があっても残さない' do
      assert_not filter.keep?(course('人01', 'humanities', language: 'german'))
      assert_not CourseFilter.new(grouped_document('field:season')).keep?(
        course('人01', 'humanities', language: 'german')
      )
    end

    test '欄ではなく科目番号で分ける規則は、科目を残す理由にしない' do
      filter = CourseFilter.new(grouped_document('number_prefix'))

      assert_not filter.keep?(course('人01', 'humanities'))
      assert_not filter.keep?(course('人02', 'humanities', language: 'german'))
    end

    test '人が確認した科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', confirmed: true))
    end

    test '人が確認し終えていない科目(もう一度確認の印つき)は、他に理由がなければ残さない' do
      assert_not filter.keep?(course('人01', 'humanities', confirmed: true, review_again: true))
    end

    test '人が手で足した科目は、パターンで決まっても残す' do
      assert filter.keep?(course('人01', 'humanities', added_by_hand: true))
    end

    test '全角や空白の混じった番号も、整えてから判定する' do
      assert_not filter.keep?(course(' 人０１ ', 'humanities'))
    end

    test '壊れた文書でも例外を出さず、すべて残す' do
      assert CourseFilter.new({}).keep?(course('人01', 'humanities'))
      broken = { 'categories' => [nil, 'x', { 'key' => 'a', 'number_patterns' => nil }] }
      assert CourseFilter.new(broken).keep?(course('人01', 'a'))
    end

    test '壊れた規則でも例外を出さず、欄で分ける規則として読まない' do
      broken = { 'categories' => DOCUMENT['categories'],
                 'rules' => [nil, 'x', { 'type' => 'grouped_max' },
                             { 'type' => 'grouped_max', 'group_by' => 'field:' },
                             { 'type' => 'grouped_max', 'group_by' => 42 },
                             { 'type' => 'any_of', 'options' => 'x' }] }

      assert_not CourseFilter.new(broken).keep?(course('人01', 'humanities', language: 'german'))
    end

    test 'partition は残すものと落とすものに分ける' do
      kept_course = course('知能301', 'advanced')
      dropped_course = course('人01', 'humanities')
      assert_equal [[kept_course], [dropped_course]], filter.partition([kept_course, dropped_course])
    end

    test 'drop_summary は件数と区分ごとの内訳を1文で返す' do
      dropped = [course('人01', 'humanities'), course('人02', 'humanities')]
      assert_equal '番号から区分が決まる科目2件は、登録しませんでした(人文系2件)。区分の科目番号のパターンで数えます。',
                   filter.drop_summary(dropped)
    end

    test 'drop_summary の内訳は件数の多い順で、同数なら categories の並び順' do
      document = { 'categories' => [{ 'key' => 'a', 'label' => 'エー', 'number_patterns' => ['A'] },
                                    { 'key' => 'b', 'label' => 'ビー', 'number_patterns' => ['B'] },
                                    { 'key' => 'c', 'label' => 'シー', 'number_patterns' => ['C'] }] }
      dropped = [course('C1', 'c'), course('B1', 'b'), course('A1', 'a'), course('C2', 'c')]
      assert_equal '番号から区分が決まる科目4件は、登録しませんでした(シー2件、エー1件、ビー1件)。区分の科目番号のパターンで数えます。',
                   CourseFilter.new(document).drop_summary(dropped)
    end

    test '落とした科目が無ければ drop_summary は空文字を返す' do
      assert_equal '', filter.drop_summary([])
    end
  end

  class NumberPatternsTest < ActiveSupport::TestCase
    CATEGORIES = [
      { 'key' => 'foreign', 'number_patterns' => ['外'] },
      { 'key' => 'english', 'number_patterns' => ['外1'] },
      { 'key' => 'core' }
    ].freeze

    def patterns = NumberPatterns.new(CATEGORIES)

    test 'category_for は百の位を接頭辞より先に見る' do
      assert_equal 'english', patterns.category_for('外101')
      assert_equal 'foreign', patterns.category_for('外201')
    end

    test 'category_for はどちらにも当たらなければ nil を返す' do
      assert_nil patterns.category_for('知能101')
      assert_nil patterns.category_for(nil)
      assert_nil patterns.category_for('')
    end

    test 'Catalogue の pattern_category_for と、同じ番号に同じ区分を返す' do
      rule = { 'type' => 'all_required', 'id' => 'r', 'label' => '必修', 'required_categories' => ['core'] }
      document = { 'courses' => [], 'categories' => CATEGORIES, 'rules' => [rule] }
      catalogue = GraduationAssessment::Catalogue.new(document)
      %w[外101 外201 外 知能101 C101 外１０１ 人01].each do |number|
        assert_equal [catalogue.pattern_category_for(number)], [patterns.category_for(number)], number
      end
    end
  end
end

