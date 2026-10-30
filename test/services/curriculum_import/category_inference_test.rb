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
  end
end

