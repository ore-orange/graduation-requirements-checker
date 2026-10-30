# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/requirements_draft_fixtures'

module CurriculumImport
  class AnnotationsTest < ActiveSupport::TestCase
    include RequirementsDraftFixtures

    def pages_with(text:, warnings: [], kind: 'requirements')
      [{ 'page' => 4, 'kind' => kind, 'status' => 'read', 'text' => text, 'warnings' => warnings }]
    end

    test '規則にも行にも書き取られなかった承認の文は、ページの文字から前後を抜いてカードにする' do
      text = "備考\n他学部提供の科目の履修登録には指導教員の承認が必要である。\nその他の注意。"
      cards = Annotations.cards({}, pages_with(text: text, warnings: [ApprovalNotes::UNWRITTEN_WARNING]))

      assert_equal [:approval_unattached], cards.map(&:kind)
      assert_includes cards.first.text, '指導教員の承認が必要'
      assert_equal 4, cards.first.page
    end

    test '文字の層が無いページでも、承認の警告はカードとして残る' do
      cards = Annotations.cards({}, pages_with(text: '', warnings: [ApprovalNotes::UNWRITTEN_WARNING]))

      assert_equal 1, cards.size
      assert_includes cards.first.text, '承認'
    end

    test 'カードの id は読み直しでも変わらず、決めた内容が戻ってくる' do
      warning = ApprovalNotes.unresolved_warning('承認が必要')
      document = requirements_document
      first = Annotations.cards(document, pages_with(text: '', warnings: [warning])).first
      assert_nil Annotations.decide(document, pages_with(text: '', warnings: [warning]), first.id, 'ignore')

      again = Annotations.cards(document, pages_with(text: '', warnings: [warning, warning])).first
      assert_equal first.id, again.id
      assert_equal 'ignore', again.decision['disposition']
    end

    test '外国人学生の語は、規則の文・行の文・要件表のページから拾い、同じ文は1つにまとめる' do
      document = requirements_document
      document['rules'][0]['detail'] = '外国人留学生の特例あり'
      document['rules'][1]['detail'] = '外国人留学生の特例あり'
      document['display']['groups'][0]['rows'][0]['subtitle'] = '留学生は別に定める'
      cards = Annotations.cards(document, pages_with(text: '備考 外国人学生の扱い。'))

      assert_equal(3, cards.count { |card| card.kind == :foreign_student })
      assert(cards.any? { |card| card.text.include?('外国人学生の扱い') && card.page == 4 })
    end

    test '科目表のページの文字は、外国人学生の語があっても拾わない(要件表だけを見る)' do
      cards = Annotations.cards({}, pages_with(text: '外国人留学生', kind: 'courses'))

      assert_empty cards
    end

    test '壊れた document・pages でも落ちない' do
      [nil, 'x',
       { 'rules' => 'x', 'display' => 3, 'approval_notes' => 4, 'annotation_decisions' => [] }].each do |document|
        assert_nothing_raised { Annotations.cards(document, [nil, 'x', { 'warnings' => 'x' }]) }
      end
    end

    # 値が空の規則が黙って通ると、注釈を規則にすると決めたのに、何も判定しないまま公開される。
    test '型を割り当てた規則は、型が要る欄が空で、数字が要る型は公開を止める。空の経路は要確認になる警告' do
      pages = pages_with(text: '外国人留学生')
      assert_equal 7, Annotations::RULE_TYPES.size

      Annotations::RULE_TYPES.each do |type|
        document = requirements_document
        card = Annotations.cards(document, pages).first
        assert_nil Annotations.decide(document, pages, card.id, type), type

        assert_equal [type, true], document['rules'].last.values_at('type', 'confirmed')
        findings = Validation.new(document, pages: []).call
        assert_predicate findings, :any?, "#{type}: 空の規則が黙って通る"
        assert_equal %w[one_of_paths any_of].include?(type), findings.none? { |finding| finding[:blocking] }, type
      end
    end
  end
end

