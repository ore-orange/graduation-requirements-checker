# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  class CategoryInferenceTest < ActiveSupport::TestCase
    def course(number, category)
      { 'key' => "course_#{number}", 'number' => number, 'name' => "科目#{number}", 'category' => category }
    end

    def inference(*rows)
      CategoryInference.new(rows.map { |number, category| course(number, category) })
    end

    def sample
      rows = (101..105).map { |n| ["人#{n}", 'humanities'] }
      rows += [%w[外101 english], %w[外102 english], %w[外201 foreign_language], %w[外202 foreign_language]]
      # 知能 は advanced と required_core にまたがる。百の位でも分かれない。
      rows += [%w[知能301 advanced], %w[知能302 required_core], %w[知能303 advanced]]
      # 知能99x は工学融合にしか現れない。そこに course_required と読まれた知能993 が混ざる。
      rows += [%w[知能991 fusion], %w[知能992 fusion], %w[知能994 fusion], %w[知能993 course_required]]
      inference(*rows)
    end

    test '1つの区分にしか現れない接頭辞は、その区分を推定する' do
      assert_equal 'humanities', sample.inferred('人106')
    end

    test '複数の区分にまたがる接頭辞は推定しない' do
      assert_nil sample.inferred('知能301')
    end

    test '百の位まで見れば決まるなら、それを使う' do
      assert_equal 'english', sample.inferred('外103')
      assert_equal 'foreign_language', sample.inferred('外203')
    end

    test '百の位でも決まらない組は推定しない' do
      assert_nil sample.inferred('知能399')
    end

    test '見たことのない百の位でも、接頭辞が1区分に決まっていればその区分を使う' do
      assert_equal 'humanities', sample.inferred('人999')
    end

    test '見たことのない接頭辞と、読めない番号は推定しない' do
      assert_nil sample.inferred('琉101')
      assert_nil sample.inferred(nil)
      assert_nil sample.inferred('知能')
    end

    test '全角や空白の混じった番号も同じ接頭辞として読む' do
      assert_equal 'humanities', sample.inferred(' 人１０６ ')
    end

    test '推定と読み取りが食い違う科目を mismatches に出す' do
      assert_equal(['知能993'], sample.mismatches.pluck(:number))
      assert_equal [{ number: '知能993', read: 'course_required', inferred: 'fusion' }], sample.mismatches
    end

    test '他の科目の根拠が少ない食い違いは出さない' do
      rows = [%w[知能991 fusion], %w[知能992 fusion], %w[知能993 course_required]]

      assert_empty inference(*rows).mismatches
    end

    test '百の位の根拠が足りなくても、同じ接頭辞の他の科目が揃っていれば食い違いを出す' do
      rows = (101..103).map { |n| ["甲#{n}", n == 103 ? 'other' : 'main'] }
      rows += (201..250).map { |n| ["甲#{n}", 'main'] }

      assert_equal [{ number: '甲103', read: 'other', inferred: 'main' }], inference(*rows).mismatches
    end

    test '決まらない接頭辞の科目は食い違いにしない' do
      rows = [%w[知能301 advanced], %w[知能302 required_core], %w[知能303 advanced], %w[知能304 related]]

      assert_empty inference(*rows).mismatches
    end

    test '番号や区分が読めない科目は、根拠にも食い違いにも入れない' do
      rows = [[nil, 'related'], ['', 'related'], ['知能', 'related'], %w[人101 humanities], ['人102', nil]]

      assert_empty inference(*rows).mismatches
      assert_equal 'humanities', inference(*rows).inferred('人103')
    end

    test '対応表は渡された科目表から毎回作る' do
      assert_equal 'a', inference(%w[甲1 a], %w[甲2 a]).inferred('甲3')
      assert_equal 'b', inference(%w[甲1 b], %w[甲2 b]).inferred('甲3')
    end

    def nums(prefix, range, category)
      range.map { |n| ["#{prefix}#{n}", category] }
    end

    def curriculum_courses
      path = Rails.root.join('config/curricula/intelligent_informatics/2024.json')
      JSON.parse(path.read)
    end

    test '百の位の鍵が1区分にしか現れず、3件以上あれば候補になる' do
      rows = nums('甲', 101..103, 'main') + nums('甲', 201..202, 'other')

      assert_equal({ 'main' => ['甲1'] }, inference(*rows).suggestions)
    end

    test '複数の区分にまたがる鍵は候補にならない' do
      rows = nums('甲', 101..103, 'main') + nums('甲', 104..105, 'other')

      assert_empty inference(*rows).suggestions
    end

    test '根拠が2件以下の鍵は候補にならない' do
      assert_empty inference(*nums('甲', 101..102, 'main')).suggestions
    end

    test '百の位で候補が出た区分には、接頭辞だけの鍵を重ねない' do
      rows = nums('乙', 101..103, 'main') + nums('乙', 201..201, 'main')

      assert_equal({ 'main' => ['乙1'] }, inference(*rows).suggestions)
    end

    test '百の位がばらけていても、接頭辞が1区分に決まり根拠が足りていれば、接頭辞の鍵を候補にする' do
      rows = nums('丙', 101..102, 'main') + nums('丙', 201..202, 'main')

      assert_equal({ 'main' => ['丙'] }, inference(*rows).suggestions)
    end

    test '接頭辞が複数の区分にまたがるなら、接頭辞の鍵は候補にならない' do
      rows = nums('丁', 101..102, 'main') + nums('丁', 201..202, 'other')

      assert_empty inference(*rows).suggestions
    end

    test '既にパターンを持つ区分には候補を出さない' do
      rows = nums('甲', 101..103, 'main') + nums('丙', 101..103, 'done')
      categories = [{ 'key' => 'main' }, { 'key' => 'done', 'number_patterns' => ['丙'] }]

      assert_equal({ 'main' => ['甲1'] }, inference(*rows).suggestions(categories))
    end

    test '2024年度の便覧から、先0〜先5・知能4・知能9・機械9・エネ9・電気9・電情9・社基9・建築9 が候補になる' do
      document = curriculum_courses
      suggestions = CategoryInference.new(document['courses']).suggestions(document['categories'])

      assert_equal %w[先0 先1 先2 先3 先4 先5], suggestions['basic']
      assert_equal ['知能4'], suggestions['related']
      assert_equal %w[エネ9 機械9 建築9 社基9 知能9 電気9 電情9].sort, suggestions['fusion'].sort
    end

    test '2024年度の便覧から、転・全教4・情0・情1 は候補にならず、共通教育の区分にも出さない' do
      document = curriculum_courses
      suggestions = CategoryInference.new(document['courses']).suggestions(document['categories'])
      all = suggestions.values.flatten

      assert_empty all & %w[転 転0 転1 転2 全教4 情0 情1]
      assert_equal %w[basic fusion related], suggestions.keys.sort
    end
  end
end

