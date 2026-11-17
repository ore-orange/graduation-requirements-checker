# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  # 科目表の読み取りが通す2つの関門。番号から区分が決まる科目は文書に入れず、同じ科目の重複は入れない。
  # 人の手にある科目の判定(human_owned?)を先に通すので、ここでは人の訂正には触れない。
  class DraftMergeFilterTest < ActiveSupport::TestCase
    class StubReader
      def initialize(courses) = @courses = courses

      def read_courses(text:, **) = @courses.fetch(text)
    end

    def category_list(with_patterns: true)
      [{ 'key' => 'humanities', 'label' => '人文系', 'counts_toward_total' => true,
         'number_patterns' => with_patterns ? ['人'] : nil }.compact,
       { 'key' => 'advanced', 'label' => '知能情報アドバンスト', 'counts_toward_total' => true }]
    end

    def row(number, name: "科目#{number}", category: 'advanced')
      { 'number' => number, 'name' => name, 'credits' => 2, 'category' => category, 'required' => false,
        'requires_approval' => false, 'language' => nil, 'review_reason' => nil, 'roles' => [] }
    end

    def build(categories: category_list)
      @curriculum = Curriculum.create!(
        slug: 'sample', admission_year: 2025, faculty_name: '工学部', department_name: '工学科',
        source_filename: 'handbook.pdf', document: { 'categories' => categories },
        pages: [{ 'page' => 9, 'kind' => 'courses', 'status' => 'pending', 'error' => nil, 'text' => '科目' }]
      )
      FileUtils.mkdir_p(@curriculum.images_dir)
      File.binwrite(@curriculum.images_dir.join('p9.png'), "\x89PNG".b)
    end

    teardown { FileUtils.rm_rf(@curriculum.images_dir) if @curriculum }

    def read(*rows)
      assert ReadPage.new(@curriculum, reader: StubReader.new('科目' => { 'courses' => rows })).call(9)
    end

    def numbers = @curriculum.reload.document['courses'].pluck('number')

    def warnings = @curriculum.reload.pages.first['warnings'].to_a

    test '番号パターンで決まる科目は、読んでも文書に入らない' do
      build
      read(row('人01', category: 'humanities'), row('知能301'))

      assert_equal ['知能301'], numbers
    end

    test '落とした件数と内訳が warnings に入る' do
      build
      read(row('人01', category: 'humanities'), row('人02', category: 'humanities'), row('知能301'))

      assert_includes warnings, '番号から区分が決まる科目2件は、登録しませんでした(人文系2件)。区分の科目番号のパターンで数えます。'
    end

    test '落ちる科目が無いときは、落とした件数の警告を出さない' do
      build
      read(row('知能301'))

      assert(warnings.none? { |sentence| sentence.include?('登録しませんでした') })
      assert(warnings.none? { |sentence| sentence.include?('重複') })
    end

    test '同じ科目番号・科目名の科目は、2回読んでも1件のまま' do
      build
      read(row('知能301'), row('知能301'))
      assert_equal ['知能301'], numbers

      read(row('知能301'))
      assert_equal ['知能301'], numbers
    end

    test '同じ科目番号で名前が違う科目は、2件とも入る' do
      build
      read(row('知能301', name: '科目A'), row('知能301', name: '科目B'))

      assert_equal %w[知能301 知能301], numbers
    end

    test '外した重複の件数が warnings に入る' do
      build
      read(row('知能301'), row('知能301'), row('知能302'), row('知能302'))

      assert_includes warnings, '科目番号と科目名が同じ科目2件は、重複なので登録しませんでした。'
    end

    test '番号の全角・空白の違いだけの重複も外す' do
      build
      read(row('知能301'), row('知能３０１ ', name: '科目知能301'), row('知能 301', name: "  科目知能301\n"))

      assert_equal ['知能301'], numbers
    end

    test '別のページが足した科目と同じ科目も、重複として外す' do
      build
      @curriculum.document['courses'] = [{ 'key' => 'course_知能301', 'number' => '知能301', 'name' => '科目知能301',
                                           'category' => 'advanced', 'selectable' => true }]
      @curriculum.save!
      read(row('知能301'), row('知能302'))

      assert_equal %w[知能301 知能302], numbers
    end

    test '重複と絞り込みの警告は、別の文になる' do
      build
      read(row('人01', category: 'humanities'), row('知能301'), row('知能301'))

      assert_equal 2, warnings.size
    end

    test '落とした科目は、読み直しの記録に入らない' do
      build
      read(row('人01', category: 'humanities'), row('知能301'))
      contributed = @curriculum.reload.pages.first['contributed']

      assert_equal 1, contributed['courses'].size
      read(row('人01', category: 'humanities'), row('知能301'))
      assert_equal ['知能301'], numbers
    end

    test 'パターンを持たない区分だけの便覧では、1件も落ちない' do
      build(categories: category_list(with_patterns: false))
      read(row('人01', category: 'humanities'), row('知能301'))

      assert_equal %w[人01 知能301], numbers
      assert(warnings.none? { |sentence| sentence.include?('登録しませんでした') })
    end
  end
end

