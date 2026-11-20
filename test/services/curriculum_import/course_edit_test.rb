# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  # 1科目の確認・修正・削除・追加(科目表の確認画面)。値の読み方と、確認済みの印の付け方を確かめる。
  class CourseEditTest < ActiveSupport::TestCase
    def course(number, **fields)
      { 'key' => "course_#{number}", 'number' => number, 'name' => "科目#{number}", 'credits' => 2, 'category' => 'core',
        'required' => false, 'language' => nil, 'roles' => [], 'source' => 'handbook', 'source_page' => 'PDF3ページ',
        'review_reason' => nil, 'requires_approval' => false, 'selectable' => true }.merge(fields.stringify_keys)
    end

    setup do
      categories = [{ 'key' => 'core', 'label' => 'コア' }, { 'key' => 'fusion', 'label' => '融合' }]
      document = { 'categories' => categories, 'courses' => [course('知能101'), course('知能103')] }
      contributed = { 'courses' => %w[course_知能101 course_知能103] }
      @curriculum = Curriculum.create!(slug: 'sample', admission_year: 2025, document: document,
                                       pages: [{ 'page' => 3, 'kind' => 'courses', 'status' => 'read',
                                                 'contributed' => contributed }])
    end

    def edit(**params)
      result = nil
      @curriculum.with_lock { result = CourseEdit.new(@curriculum, params).call }
      result
    end

    def stored(number = '知能101') = @curriculum.reload.document['courses'].find { |entry| entry['number'] == number }

    test '送られた欄だけを直し、確認済みにする。ほかの欄・ほかの科目は変わらない' do
      result = edit(key: 'course_知能101', credits: '3', name: '直した')

      assert_predicate result, :ok?
      assert_equal %w[name credits].sort, result.changed.sort
      assert_equal({ 'credits' => 3, 'name' => '直した', 'confirmed' => true },
                   stored.slice('credits', 'name', 'confirmed'))
      assert_equal 'core', stored['category']
      assert_nil stored('知能103')['confirmed']
    end

    test '触っていない欄を送り返しても、直したことにならず、確認済みの印も付かない' do
      result = edit(key: 'course_知能101', number: '知能101', name: '科目知能101', credits: '2', category: 'core',
                    required: '0', requires_approval: '0', selectable: '1', language: '', roles: '', review_reason: '')

      assert_predicate result, :ok?
      assert_empty result.changed
      assert_equal ['変えた箇所はありませんでした。'], result.notes
      assert_nil stored['confirmed']
    end

    test '確認だけの操作は確認済みの印を付け、確認を外す操作は外す。値を変えながら外すことはできない' do
      edit(key: 'course_知能101', confirmed: 'true')
      assert_equal true, stored['confirmed']

      edit(key: 'course_知能101', confirmed: 'false')
      assert_equal false, stored['confirmed']

      edit(key: 'course_知能101', credits: '4', confirmed: 'false')
      assert_equal true, stored['confirmed']
    end

    test 'はい/いいえの欄は、読めない値を断る' do
      result = edit(key: 'course_知能101', selectable: 'たぶん')

      assert_not_predicate result, :ok?
      assert_match(/学生が選べるかは「はい・いいえ」で入れてください/, result.errors.first)
      assert_equal true, stored['selectable']
    end

    test '単位は 0〜20 の数。小数と全角は受け、文字・負・大きすぎる値は断る' do
      assert_predicate edit(key: 'course_知能101', credits: '０.５'), :ok?
      assert_in_delta(0.5, stored['credits'])
      assert_predicate edit(key: 'course_知能101', credits: '0'), :ok?

      ['', '-1', '21', '二単位', '2単位'].each do |bad|
        result = edit(key: 'course_知能101', credits: bad)
        assert_not_predicate result, :ok?, "#{bad.inspect} を受けてしまった"
      end
      assert_equal 0, stored['credits']
    end

    test '番号を空にしたり、ほかの科目と同じにしたりはできない' do
      assert_not_predicate edit(key: 'course_知能101', number: '知能103'), :ok?
      assert_not_predicate edit(key: 'course_知能101', number: ' '), :ok?
      assert_equal '知能101', stored['number']
      assert_predicate edit(key: 'course_知能101', number: '知能101'), :ok?, '自分の番号は、そのまま送れる'
    end

    test '全部の問題を一度に返し、何も保存しない' do
      result = edit(key: 'course_知能101', name: '', credits: 'x', category: 'nothing')

      assert_equal 3, result.problems.size
      assert(result.problems.all? { |problem| problem.kind == 'course' && problem.id == 'course_知能101' })
      assert_equal '科目知能101', stored['name']
    end

    test '役割は、カンマ区切りで一覧にして持つ' do
      edit(key: 'course_知能101', roles: 'calculus, 微分積分 ')

      assert_equal %w[calculus 微分積分], stored['roles']
    end

    test '手で足した科目を消すときは、読み直しの記録を残さない' do
      edit(added_by_hand: '1', number: '知能999', name: '足した', credits: '2', category: 'core')
      assert_predicate edit(key: 'course_知能999', _destroy: '1'), :ok?

      assert_nil stored('知能999')
      assert_nil @curriculum.document['removed_by_human']
    end

    test 'courses が無い下書きにも、科目を足せる' do
      empty = Curriculum.create!(slug: 'empty', admission_year: 2025,
                                 document: { 'categories' => [{ 'key' => 'core', 'label' => 'コア' }] })
      result = empty.with_lock do
        CourseEdit.new(empty, added_by_hand: '1', number: '知能1', name: '足した', credits: '2', category: 'core').call
      end

      assert_predicate result, :ok?
      assert_equal %w[知能1], empty.reload.document['courses'].pluck('number')
    end

    test '足した科目の key は、既存の key とぶつからない' do
      document = @curriculum.document
      document['courses'] << course('別番号', key: 'course_知能105')
      @curriculum.update!(document: document)

      edit(added_by_hand: '1', number: '知能105', name: '足した', credits: '2', category: 'core')

      assert_equal 'course_知能105_hand2', stored('知能105')['key']
    end

    test '画面の指紋が違えば断り、何も変えない。指紋が合えば通る' do
      fingerprint = CourseEdit.fingerprint(stored)

      assert_predicate edit(key: 'course_知能101', credits: '3'), :ok?
      result = edit(key: 'course_知能101', credits: '4', rev: fingerprint)

      assert_predicate result, :stale
      assert_equal 3, stored['credits']
      assert_predicate edit(key: 'course_知能101', credits: '4', rev: CourseEdit.fingerprint(stored)), :ok?
    end
  end
end

