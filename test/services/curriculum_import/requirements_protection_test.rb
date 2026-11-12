# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  # 人が確認画面で直した規則・章・行・総単位・区分が、そのページの読み直しで AI の読みに戻らないこと。
  # 直す入口(RequirementsEdit)と読み直しの入口(ReadPage)を、本物のまま通して確かめる。
  class RequirementsProtectionTest < ActiveSupport::TestCase
    class StubReader
      def initialize(requirements)
        @requirements = requirements
      end

      def read_requirements(text:, **)
        @requirements.fetch(text)
      end
    end

    CATEGORIES = [{ 'key' => 'natural', 'label' => '自然系', 'counts_toward_total' => true },
                  { 'key' => 'social', 'label' => '社会系', 'counts_toward_total' => true }].freeze

    # 規則1つ・章1つ(行2つ)・小計1つの、1ページ分の答え。value を変えれば、読み直した答えが変わる。
    def answer(credits: 30, total: 130, label: '共通教育', categories: CATEGORIES, group_id: 'g1', row_two: true)
      rows = [row('r1', '自然系', credits)] + (row_two ? [row('r2', '社会系', 2)] : [])
      { 'categories' => categories, 'roles' => [],
        'rules' => [{ 'id' => 'common_total', 'type' => 'credit_sum', 'label' => label, 'categories' => ['natural'],
                      'required_credits' => credits, 'detail' => nil }],
        'display' => { 'total_credits' => total,
                       'groups' => [{ 'id' => group_id, 'title' => '1. 共通教育', 'required_credits' => credits,
                                      'check_id' => 'common_total', 'rows' => rows }],
                       'subtotals' => [{ 'id' => 's1', 'name' => '小計', 'required_credits' => credits,
                                         'row_ids' => ['r1'], 'check_ids' => ['common_total'] }] } }
    end

    def row(id, name, credits)
      { 'id' => id, 'name' => name, 'subtitle' => nil, 'required_credits' => credits, 'required_label' => nil,
        'categories' => ['natural'], 'check_ids' => ['common_total'], 'credits_from_check' => false }
    end

    setup do
      @curriculum = Curriculum.create!(
        slug: 'sample', admission_year: 2025, faculty_name: '工学部', department_name: '工学科',
        source_filename: 'handbook.pdf',
        pages: [{ 'page' => 3, 'kind' => 'requirements', 'status' => 'pending', 'error' => nil, 'text' => '要件' }]
      )
      FileUtils.mkdir_p(@curriculum.images_dir)
      File.binwrite(@curriculum.images_dir.join('p3.png'), "\x89PNG".b)
    end

    teardown { FileUtils.rm_rf(@curriculum.images_dir) }

    def read(**)
      ReadPage.new(@curriculum, reader: StubReader.new('要件' => answer(**))).call(3)
    end

    # 確認画面の保存と同じ道(RequirementsEdit)で直す。
    def edit(**params)
      result = nil
      @curriculum.with_lock do
        signed = params.merge(revision: RequirementsEdit.revision(@curriculum.document))
        result = RequirementsEdit.new(@curriculum, signed).call
      end
      assert_predicate result, :ok?, result.errors.inspect
      result
    end

    def document = @curriculum.reload.document

    def rule(id) = document['rules'].find { |entry| entry['id'] == id }

    def group(id) = document['display']['groups'].find { |entry| entry['id'] == id }

    def contributed = @curriculum.reload.pages.first['contributed']

    def warnings = @curriculum.reload.pages.first['warnings']

    test '直した規則は、読み直しても AI の値に戻らず、二重にもならない' do
      read
      edit(rules: [{ id: 'common_total', required_credits: '37' }])
      assert read(credits: 38)

      assert_equal [37], document['rules'].pluck('required_credits')
      assert_equal %w[common_total], document['rules'].pluck('id')
      assert_equal %w[common_total], contributed['rules'], '残した規則も、このページの記録に残る(次の読み直しでも守る)'
    end

    test '読み直した値が違えば、黙って捨てずに、そのページの警告に残す' do
      read
      edit(rules: [{ id: 'common_total', required_credits: '37' }])
      read(credits: 38)

      assert(warnings.any? do |text|
        text.include?('規則「common_total」は人が直した内容を残しました') && text.include?('必要単位(残した値: 37 / 読み直した値: 38)')
      end)
    end

    test '読み直した値が、直した値と同じなら、警告は出ない' do
      read
      edit(rules: [{ id: 'common_total', required_credits: '31' }])
      read(credits: 31)

      assert_empty(warnings.grep(/人が直した内容を残しました/).reject { |text| text.include?('章') || text.include?('小計') })
    end

    test '何度読み直しても、直した値は変わらず、増えもしない' do
      read
      edit(rules: [{ id: 'common_total', required_credits: '37' }])
      3.times { read(credits: 38) }

      assert_equal [37], document['rules'].pluck('required_credits')
      assert_equal 1, document['rules'].size
      assert_equal 1, document['display']['groups'].size
    end

    test '直していない規則は、これまでどおり読み直しで入れ替わる' do
      read
      read(label: '共通教育(直った)', credits: 31)

      assert_equal ['共通教育(直った)', 31], rule('common_total').values_at('label', 'required_credits')
      assert_nil rule('common_total')['confirmed']
    end

    test '行を1つ直すと、その章は章ごと残り、AI の章は足されない' do
      read
      edit(display: { groups: [{ id: 'g1', rows: [{ id: 'r1', name: '自然系(直した)' }] }] })
      read(credits: 40)

      assert_equal([['自然系(直した)', 30], ['社会系', 2]], group('g1')['rows'].map do |entry|
        entry.values_at('name', 'required_credits')
      end)
      assert_equal 30, group('g1')['required_credits'], '直していない値も、章が残るので AI の新しい値には変わらない'
      assert_equal 1, document['display']['groups'].size
      assert_equal %w[g1], contributed['groups']
      assert(warnings.any? { |text| text.include?('章「g1」は人が直した内容を残しました') && text.include?('行「r1」の必要単位') })
    end

    test '直した小計も残る' do
      read
      edit(display: { subtotals: [{ id: 's1', name: '小計(直した)', required_credits: '9' }] })
      read(credits: 40)

      assert_equal([['小計(直した)', 9]], document['display']['subtotals'].map do |entry|
        entry.values_at('name', 'required_credits')
      end)
      assert_equal %w[s1], contributed['subtotals']
    end

    test '人が消した規則・章・行は、読み直しても戻らない' do
      read
      edit(rules: [{ id: 'common_total', _destroy: '1' }],
           display: { groups: [{ id: 'g1', rows: [{ id: 'r2', _destroy: '1' }] }] })
      read

      assert_empty document['rules']
      assert_equal %w[r1], group('g1')['rows'].pluck('id')
      edit(display: { groups: [{ id: 'g1', _destroy: '1' }] })
      read

      assert_empty document['display']['groups']
      assert_empty contributed['rules']
    end

    test '消した規則を指す行は、突き合わせが「規則が見つかりません」で止める(黙って判定から消えない)' do
      read
      edit(rules: [{ id: 'common_total', _destroy: '1' }])
      read

      findings = Validation.for(@curriculum.reload).call
      assert(findings.any? { |finding| finding[:blocking] && finding[:reason].include?('規則が見つかりません: common_total') })
    end

    test '消した章を、別の ID で読み直してしまっても、同じ章は戻さない' do
      read(group_id: 'g1')
      edit(display: { groups: [{ id: 'g1', _destroy: '1' }] })
      read(group_id: 'g1')
      assert_empty document['display']['groups']
    end

    test '直した総単位は、読み直しで AI の値に戻らず、食い違いを警告に残す' do
      read
      edit(display: { total_credits: '128' })
      read(total: 130)

      assert_equal 128, document['display']['total_credits']
      assert(warnings.any? { |text| text.include?('卒業に必要な総単位は、人が直した値(128)を残しました(読み直した結果: 130)') })
      assert_equal 'human', contributed['total_credits']
    end

    test '直していない総単位は、読み直しで入れ替わる' do
      read
      read(total: 120)

      assert_equal 120, document['display']['total_credits']
    end

    test '直した区分は、読み直しで名前も、総単位に数えるかも変わらない' do
      read
      edit(categories: [{ key: 'social', label: '社会系(直した)', counts_toward_total: '0' }])
      read(categories: [{ 'key' => 'social', 'label' => '社会', 'counts_toward_total' => true },
                        { 'key' => 'natural', 'label' => '自然系', 'counts_toward_total' => false }])

      social = document['categories'].find { |entry| entry['key'] == 'social' }
      assert_equal ['社会系(直した)', false, true], [social['label'], social['counts_toward_total'], social['confirmed']]
      natural = document['categories'].find { |entry| entry['key'] == 'natural' }
      assert_equal false, natural['counts_toward_total'], '直していない区分は、これまでどおり数えない側に倒す'
      assert(warnings.any? { |text| text.include?('区分 social の名前は、人が直した「社会系(直した)」を残しました') })
    end

    test '種別を替えても、人が直した規則は残り、記録に引き継がれる' do
      read
      edit(rules: [{ id: 'common_total', required_credits: '37' }])
      @curriculum.assign_page_kinds('3' => 'courses')
      @curriculum.save!

      assert_equal [37], document['rules'].pluck('required_credits')
      assert_equal %w[common_total], contributed['rules']

      @curriculum.assign_page_kinds('3' => 'requirements')
      @curriculum.save!
      read(credits: 38)
      assert_equal [37], document['rules'].pluck('required_credits')
      assert_equal 1, document['rules'].size
    end

    test '直していないものだけの種別替えは、これまでどおり外れる' do
      read
      @curriculum.assign_page_kinds('3' => 'skip')
      @curriculum.save!

      assert_empty document['rules']
      assert_empty document['display']['groups']
      assert_nil @curriculum.pages.first['contributed']
    end

    test '読み直す前の警告は、残すものと戻さないものを言い、直したものが無ければ何も言わない' do
      read
      assert_nil RereadWarning.for(document, @curriculum.pages.first)

      edit(rules: [{ id: 'common_total', required_credits: '37' }],
           display: { groups: [{ id: 'g1', rows: [{ id: 'r2', _destroy: '1' }] }] })
      text = RereadWarning.for(document, @curriculum.reload.pages.first)

      assert_includes text, '3ページを読み直します'
      assert_includes text, '規則: 共通教育(common_total)'
      assert_includes text, '行「r2」'
      assert_includes text, '入れ替わります'
    end

    test '注釈から足した規則も、読み直しで消えない' do
      read
      edit(new_rule: { type: 'credit_sum', label: '追加', categories: ['natural'], required_credits: '2' })
      read(credits: 31)

      assert_equal %w[added_rule_1 common_total], document['rules'].pluck('id').sort
    end
  end
end

