# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  # 別のページの id とぶつかって付け替えられた(common_total → common_total_p4)規則・章・小計・行も、
  # 人が直したものは読み直しで守られること。守りが読んだ id だけで照らすと、付け替えられたものは一致せず、
  # 直したものと AI の読みが並び、行は AI の規則を指す(直した規則は、画面に出ないまま判定には使われる)。
  class RequirementsProtectionCollisionTest < ActiveSupport::TestCase
    class StubReader
      def initialize(answers)
        @answers = answers
      end

      def read_requirements(text:, **)
        @answers.fetch(text)
      end
    end

    CATEGORIES = [{ 'key' => 'natural', 'label' => '自然系', 'counts_toward_total' => true }].freeze

    def rule(id, credits)
      { 'id' => id, 'type' => 'credit_sum', 'label' => id, 'categories' => ['natural'], 'required_credits' => credits }
    end

    def row(id, credits, rule_id)
      { 'id' => id, 'name' => "行#{id}", 'subtitle' => nil, 'required_credits' => credits, 'required_label' => nil,
        'categories' => ['natural'], 'check_ids' => [rule_id], 'credits_from_check' => false }
    end

    # 2つのページが、同じ id の規則・章・小計(と、同じ id の行2つ)を返す。
    def answer(credits, rules: nil)
      rules ||= [rule('common_total', credits)]
      { 'categories' => CATEGORIES, 'roles' => [], 'rules' => rules,
        'display' => { 'groups' => [{ 'id' => 'g1', 'title' => '共通教育', 'required_credits' => credits,
                                      'check_id' => 'common_total',
                                      'rows' => [row('r1', credits, 'common_total'), row('r2', 2, 'common_total')] }],
                       'subtotals' => [{ 'id' => 's1', 'name' => '小計', 'required_credits' => credits,
                                         'row_ids' => ['r1'], 'check_ids' => ['common_total'] }] } }
    end

    setup do
      pages = [3, 4].map do |n|
        { 'page' => n, 'kind' => 'requirements', 'status' => 'pending', 'error' => nil, 'text' => "p#{n}" }
      end
      @curriculum = Curriculum.create!(slug: 'sample', admission_year: 2025, faculty_name: '工学部',
                                       department_name: '工学科', source_filename: 'h.pdf', pages: pages)
      FileUtils.mkdir_p(@curriculum.images_dir)
      [3, 4].each { |n| File.binwrite(@curriculum.images_dir.join("p#{n}.png"), "\x89PNG".b) }
    end

    teardown { FileUtils.rm_rf(@curriculum.images_dir) }

    def read(page, answer) = ReadPage.new(@curriculum, reader: StubReader.new("p#{page}" => answer)).call(page)

    def edit(**params)
      result = nil
      @curriculum.with_lock do
        params[:revision] = RequirementsEdit.revision(@curriculum.document)
        result = RequirementsEdit.new(@curriculum, params).call
      end
      assert_predicate result, :ok?, result.errors.inspect
    end

    def document = @curriculum.reload.document

    def rules = document['rules'].to_h { |entry| [entry['id'], entry['required_credits']] }

    def group_ids = document['display']['groups'].pluck('id')

    def warnings(page) = @curriculum.reload.pages.find { |entry| entry['page'] == page }['warnings']

    def read_both
      read(3, answer(30))
      read(4, answer(31))
    end

    test '前提: 2つ目のページの id は付け替えられる' do
      read_both

      assert_equal({ 'common_total' => 30, 'common_total_p4' => 31 }, rules)
      assert_equal %w[g1 g1_p4], group_ids
    end

    test '付け替えられた規則を直すと、読み直しでも直した値が残り、AI の規則は並ばない' do
      read_both
      edit(rules: [{ id: 'common_total_p4', required_credits: '37' }])
      read(4, answer(38))

      assert_equal({ 'common_total' => 30, 'common_total_p4' => 37 }, rules)
      assert(warnings(4).any? do |text|
        text.include?('規則「common_total_p4」は人が直した内容を残しました') && text.include?('残した値: 37 / 読み直した値: 38')
      end)
    end

    test '直した規則を指す行は、読み直しても直した規則を指したまま' do
      read_both
      edit(rules: [{ id: 'common_total_p4', required_credits: '37' }])
      read(4, answer(38))

      chapter = document['display']['groups'].find { |group| group['id'] == 'g1_p4' }
      assert_equal [['common_total_p4'], ['common_total_p4']], chapter['rows'].pluck('check_ids')
      assert_equal 'common_total_p4', chapter['check_id']
      # AI の38と直した37の食い違いは、突き合わせが見せる(AI の読みで黙って上書きされない)。
      reasons = Validation.for(@curriculum.reload).call.pluck(:reason)
      assert(reasons.any? { |reason| reason.include?('章「g1_p4」の必要単位(38)が、規則「common_total_p4」の必要単位(37)と違います') })
      assert(reasons.none? { |reason| reason.include?('規則が見つかりません') })
    end

    test '付け替えられた章(行を直した章)も小計も、読み直しで二重にならず、直した値が残る' do
      read_both
      edit(display: { groups: [{ id: 'g1_p4', rows: [{ id: 'r1_p4', name: '直した行' }] }],
                      subtotals: [{ id: 's1_p4', name: '直した小計' }] })
      read(4, answer(38))

      assert_equal %w[g1 g1_p4], group_ids
      assert_equal ['直した行'], document['display']['groups'].last['rows'].pluck('name').first(1)
      assert_equal %w[小計 直した小計], document['display']['subtotals'].pluck('name')
      assert(warnings(4).any? { |text| text.include?('章「g1_p4」は人が直した内容を残しました') })
      assert(warnings(4).any? { |text| text.include?('小計「s1_p4」は人が直した内容を残しました') })
    end

    test '何度読み直しても、付け替えられたものは増えない' do
      read_both
      edit(rules: [{ id: 'common_total_p4', required_credits: '37' }])
      3.times { read(4, answer(38)) }

      assert_equal %w[common_total common_total_p4], rules.keys
    end

    test '1つの答えが同じ id を2回返しても、直した方が直したまま残る' do
      two = [rule('dup', 10), rule('dup', 20)]
      read(3, answer(30, rules: two))
      assert_equal({ 'dup' => 10, 'dup_p3' => 20 }, rules)

      edit(rules: [{ id: 'dup_p3', required_credits: '25' }])
      read(3, answer(30, rules: [rule('dup', 11), rule('dup', 21)]))

      assert_equal({ 'dup' => 11, 'dup_p3' => 25 }, rules)
    end

    test '1つの答えが同じ id を2回返し、1つ目を直したときも、取り違えない' do
      read(3, answer(30, rules: [rule('dup', 10), rule('dup', 20)]))
      edit(rules: [{ id: 'dup', required_credits: '15' }])
      read(3, answer(30, rules: [rule('dup', 11), rule('dup', 21)]))

      assert_equal({ 'dup' => 15, 'dup_p3' => 21 }, rules)
    end

    test '付け替えられた規則を消すと、読み直しでも戻らない(別のページの同じ id が空いても)' do
      read_both
      edit(rules: [{ id: 'common_total_p4', _destroy: '1' }])
      read(4, answer(38))
      assert_equal({ 'common_total' => 30 }, rules)

      # 別のページの規則も消すと、読み直した規則は付け替えなしの id になる。それでも、同じ由来として戻さない。
      edit(rules: [{ id: 'common_total', _destroy: '1' }])
      read(4, answer(38))
      assert_empty rules
    end

    test '付け替えられた章の行を消すと、読み直しでも戻らない' do
      read_both
      edit(display: { groups: [{ id: 'g1_p4', rows: [{ id: 'r2_p4', _destroy: '1' }] }] })
      read(4, answer(38))

      assert_equal %w[r1_p4], document['display']['groups'].find { |group| group['id'] == 'g1_p4' }['rows'].pluck('id')
    end

    test '消した章は、付け替えられた id でも戻らない' do
      read_both
      edit(display: { groups: [{ id: 'g1_p4', _destroy: '1' }] })
      read(4, answer(38))

      assert_equal %w[g1], group_ids
    end

    test '由来の記録が無い(古い)下書きでも、付け替えのないものは今までどおり守られる' do
      read(3, answer(30))
      edit(rules: [{ id: 'common_total', required_credits: '37' }])
      pages = @curriculum.reload.pages.map do |page|
        page.merge('contributed' => page['contributed']&.except('origins'))
      end
      @curriculum.update!(pages: pages)
      read(3, answer(38))

      assert_equal({ 'common_total' => 37 }, rules)
    end
  end
end

