# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  # 人が科目表の確認画面で確認した・直した・消した・足した科目が、そのページの読み直しで失われないこと。
  # 直す入口(CourseEdit)と読み直しの入口(ReadPage)を、本物のまま通して確かめる。
  # 規則・章・行(Task 18)と同じく、読み直しは人の判断を、素通りも、二重にも、取り消しにもしてはいけない。
  class CoursesProtectionTest < ActiveSupport::TestCase
    class StubReader
      def initialize(courses) = @courses = courses

      def read_courses(text:, **) = @courses.fetch(text)
    end

    CATEGORIES = [{ 'key' => 'core', 'label' => 'コア', 'counts_toward_total' => true },
                  { 'key' => 'fusion', 'label' => '工学融合', 'counts_toward_total' => true }].freeze

    def row(number, name: "科目#{number}", credits: 2, category: 'core', required: false)
      { 'number' => number, 'name' => name, 'credits' => credits, 'category' => category, 'required' => required,
        'requires_approval' => false, 'language' => nil, 'review_reason' => nil, 'roles' => [] }
    end

    setup do
      @curriculum = Curriculum.create!(
        slug: 'sample', admission_year: 2025, faculty_name: '工学部', department_name: '工学科',
        source_filename: 'handbook.pdf', document: { 'categories' => CATEGORIES },
        pages: [{ 'page' => 9, 'kind' => 'courses', 'status' => 'pending', 'error' => nil, 'text' => '科目' }]
      )
      FileUtils.mkdir_p(@curriculum.images_dir)
      File.binwrite(@curriculum.images_dir.join('p9.png'), "\x89PNG".b)
    end

    teardown { FileUtils.rm_rf(@curriculum.images_dir) }

    def read(*rows)
      rows = [row('知能101'), row('知能103')] if rows.empty?
      assert ReadPage.new(@curriculum, reader: StubReader.new('科目' => { 'courses' => rows })).call(9)
    end

    # 確認画面の保存と同じ道(CourseEdit)。行をロックした中で呼ぶ。
    def edit(**params)
      result = nil
      @curriculum.with_lock { result = CourseEdit.new(@curriculum, params).call }
      assert_predicate result, :ok?, result.errors.inspect
      result
    end

    def courses = @curriculum.reload.document['courses']

    def course(number) = courses.find { |entry| entry['number'] == number }

    def warnings = @curriculum.reload.pages.first['warnings']

    def key(number) = course(number)['key']

    test '直した科目は、読み直しても AI の値に戻らず、二重にもならず、違いは警告に残る' do
      read
      edit(key: key('知能103'), credits: '3')

      read(row('知能101'), row('知能103', credits: 4))

      assert_equal 3, course('知能103')['credits']
      assert_equal 2, courses.size
      assert_match(%r{科目「知能103」は人が直した内容を残しました.*単位\(残した値: 3 / 読み直した値: 4\)}, warnings.join)
    end

    test '確認しただけの科目も、読み直しで置き換わらない' do
      read
      edit(key: key('知能101'), confirmed: true)

      read(row('知能101', credits: 9), row('知能103', credits: 9))

      assert_equal 2, course('知能101')['credits']
      assert_equal 9, course('知能103')['credits'], '確認していない科目は、読み直した値に入れ替わる'
    end

    test '番号を直した科目は、読み直しで、AI が読んだ番号の行が二重に入らない' do
      read
      edit(key: key('知能103'), number: '知能108')
      edit(key: key('知能108'), number: '知能103')
      edit(key: key('知能103'), number: '知能109')

      read # AI は、また知能103と読む(間違いのまま)

      assert_equal %w[知能101 知能109], courses.pluck('number').sort
      assert_equal '知能103', course('知能109')['read_as'], '最初の読みを残す(直すたびに上書きしない)'
    end

    test '番号を直さず名前だけ直した科目は、読み直しで二重に入らない' do
      read
      edit(key: key('知能103'), name: '直した名前')

      read

      assert_equal 2, courses.size
      assert_equal '直した名前', course('知能103')['name']
    end

    test '消した科目は、読み直しても戻らない。同じ読みの行を2つ読んで1つ消したなら、1つ残る' do
      read(row('知能101'), row('知能103'), row('知能103', name: '重複した行'))
      edit(key: key('知能103'), _destroy: '1')
      assert_equal 2, courses.size

      read(row('知能101'), row('知能103'), row('知能103', name: '重複した行'))

      assert_equal(1, courses.count { |entry| entry['number'] == '知能103' })
      assert_equal 2, courses.size
    end

    test '消した科目は、AI が番号の前後に空白を残して返しても、読み直しで戻らない' do
      read(row(' 知能103 '), row('知能101'))
      edit(key: key('知能103'), _destroy: '1')

      read(row(' 知能103 '), row('知能101'))

      assert_equal %w[知能101], courses.pluck('number')
    end

    test '番号が空白だけの科目(番号なし)も、消せば読み直しで戻らず、直せば二重に入らない' do
      read(row('  ', name: '番号のない科目'), row('知能101'))
      assert_nil course('')&.dig('number').presence, '空白だけの番号は空として持つ'
      keys = courses.reject { |entry| entry['number'] == '知能101' }.pluck('key')
      edit(key: keys.first, credits: '3')

      read(row('  ', name: '番号のない科目'), row('知能101'))

      assert_equal 2, courses.size, '直した番号なしの科目が、二重に入った'
      edit(key: keys.first, _destroy: '1')
      read(row('  ', name: '番号のない科目'), row('知能101'))
      assert_equal %w[知能101], courses.pluck('number')
    end

    test '英字の大文字小文字だけが揺れても、同じ科目として扱う。消した科目は戻らず、直した科目は二重に入らない' do
      read(row('C101'), row('知能101'))
      edit(key: key('C101'), credits: '3')

      read(row('c101'), row('知能101'))
      assert_equal 2, courses.size
      assert_equal 3, course('C101')['credits']

      edit(key: key('C101'), _destroy: '1')
      read(row('Ｃ101'), row('知能101'))
      assert_equal %w[知能101], courses.pluck('number')
    end

    test '番号のない科目は、AI が名前に全角の空白や語中の空白を入れても、同じ科目として扱う(直した科目が二重に入らない)' do
      read(row(nil, name: '情報工学'), row('知能101'))
      edit(key: courses.find { |entry| entry['number'].nil? }['key'], credits: '3')

      ['　情報工学', '情報 工学', '情報工学　'].each do |name|
        read(row(nil, name: name), row('知能101'))

        assert_equal 2, courses.size, "#{name.inspect} で二重に入った"
        assert_equal 3, courses.find { |entry| entry['number'].nil? }['credits']
      end
    end

    test '番号のない科目を消したら、AI が名前の空白だけ変えて読み直しても、戻らない' do
      read(row(nil, name: '情報工学'), row('知能101'))
      edit(key: courses.find { |entry| entry['number'].nil? }['key'], _destroy: '1')

      read(row(nil, name: '　情報工学'), row('知能101'))

      assert_equal %w[知能101], courses.pluck('number')
    end

    test '科目を消した旨の文は、戻らない保証ではなく、実際に起きることを言う' do
      read
      result = edit(key: key('知能103'), _destroy: '1')

      assert_includes result.notes.first, '同じ読みの行は入れません'
      assert_includes result.notes.first, '内容が変わっていれば、警告をつけて入ります'
      assert_no_match(/読み直しても戻りません/, result.notes.first)
      assert_includes RereadWarning.for(@curriculum.reload.document, @curriculum.pages.first),
                      '読み直した内容が変わっていれば、警告をつけて入ります'
    end

    test '同じ番号の2行のうち、あとの行を消したら、読み直しで消した行が戻らず、残した行が残る' do
      read(row('知能103', name: 'ただしい', credits: 3), row('知能103', name: 'まちがい', credits: 8))
      wrong = courses.find { |entry| entry['name'] == 'まちがい' }
      edit(key: wrong['key'], _destroy: '1')
      assert_equal([%w[ただしい 3]], courses.map { |entry| [entry['name'], entry['credits'].to_s] })

      read(row('知能103', name: 'ただしい', credits: 3), row('知能103', name: 'まちがい', credits: 8))

      assert_equal([%w[ただしい 3]], courses.map { |entry| [entry['name'], entry['credits'].to_s] })
    end

    test '消した行の内容が変わって戻ってきたら、入れるが、消した記録と同じ番号だと警告に残す' do
      read(row('知能103', credits: 3))
      edit(key: key('知能103'), _destroy: '1')

      read(row('知能103', credits: 8))

      assert_equal 1, courses.size
      assert_match(/人が消した科目と同じ番号の行\(知能103\).*内容が違うため入れました/, warnings.join)
    end

    test '直した値を持つ科目の確認を外すと、読み直しで AI の読みに入れ替わる。その前に、警告が先に言う' do
      read
      edit(key: key('知能103'), credits: '3')
      result = edit(key: key('知能103'), confirmed: 'false')
      assert_match(/読み直すと、AI の読みに入れ替わります/, result.notes.first)

      text = RereadWarning.for(@curriculum.reload.document, @curriculum.pages.first)
      assert_match(/確認を外した次の科目は.*知能103 科目知能103/m, text)

      read
      assert_equal 2, course('知能103')['credits']
    end

    test '番号を直した科目の、直す前の読みは、種別を替えて読み直しても残り、二重に入らない' do
      read
      edit(key: key('知能103'), number: '知能108')

      @curriculum.reload.assign_page_kinds('9' => 'skip')
      @curriculum.save!
      @curriculum.assign_page_kinds('9' => 'courses')
      @curriculum.save!
      read

      assert_equal %w[知能101 知能108], courses.pluck('number').sort
      assert_equal '知能103', course('知能108')['read_as']
    end

    test '確認済みの科目に承認の注記があとから付いても、確認は外れず、もう一度見る印が付く。確認し直すと外れる' do
      read
      edit(key: key('知能101'), credits: '3')
      ApprovalNotes.add(@curriculum, 'scope' => 'category', 'category' => 'core', 'text' => '承認が要る',
                                     'source_page' => 'PDF3ページ')

      assert course('知能101')['requires_approval']
      assert_equal true, course('知能101')['confirmed'], '確認を外すと、直した単位まで読み直しで戻る'
      assert_equal true, course('知能101')['review_again']
      assert_nil course('知能103')['review_again'], '確認していない科目には付けない'

      read(row('知能101', credits: 9), row('知能103'))
      assert_equal 3, course('知能101')['credits']

      edit(key: key('知能101'), confirmed: 'true')
      assert_nil course('知能101')['review_again']
    end

    test '消した科目が、ほかの科目を巻き込まない' do
      read
      edit(key: key('知能103'), _destroy: '1')

      read(row('知能101'), row('知能103'), row('知能104'))

      assert_equal %w[知能101 知能104], courses.pluck('number').sort
    end

    test '確認済みの科目を消したあとも、読み直しで戻らない' do
      read
      edit(key: key('知能103'), confirmed: true)
      edit(key: key('知能103'), _destroy: '1')

      read

      assert_equal %w[知能101], courses.pluck('number')
    end

    test '消した記録は、科目を消した数だけ。足し直した科目の読みは外れる' do
      read
      edit(key: key('知能103'), _destroy: '1')
      edit(added_by_hand: '1', number: '知能103', name: '足し直した', credits: '2', category: 'core')

      assert_empty(@curriculum.reload.document['removed_by_human'].to_a.select { |entry| entry['kind'] == 'course' })
    end

    test '手で足した科目は、読み直しで消えず、同じ番号の行も二重に入らない。警告に残る' do
      read
      edit(added_by_hand: '1', number: '知能999', name: '足した科目', credits: '2', category: 'fusion')

      read(row('知能101'), row('知能103'), row('知能999', name: 'AIが読んだ同じ科目'))

      assert_equal(1, courses.count { |entry| entry['number'] == '知能999' })
      assert_equal '足した科目', course('知能999')['name']
      assert_match(/手で足した科目「知能999 足した科目」と同じ行/, warnings.join)
    end

    test '手で足した科目は、ページの種別を替えても残る' do
      read
      edit(added_by_hand: '1', number: '知能999', name: '足した科目', credits: '2', category: 'fusion')

      @curriculum.reload.assign_page_kinds('9' => 'skip')
      @curriculum.save!

      assert_equal %w[知能999], courses.pluck('number')
    end

    test '直した科目は、種別を替えても残り、読み直しで二重にならない' do
      read
      edit(key: key('知能103'), credits: '3')

      @curriculum.reload.assign_page_kinds('9' => 'skip')
      @curriculum.save!
      @curriculum.assign_page_kinds('9' => 'courses')
      @curriculum.save!
      read

      assert_equal 2, courses.size
      assert_equal 3, course('知能103')['credits']
    end

    test '消した科目の記録は、要件表の画面の revision を変えない' do
      read
      before = RequirementsEdit.revision(@curriculum.reload.document)

      edit(key: key('知能103'), _destroy: '1')

      assert_equal before, RequirementsEdit.revision(@curriculum.reload.document)
    end

    test '読み直す前の警告に、人が確認した科目の数と、消した科目が出る' do
      read
      edit(key: key('知能101'), confirmed: true)
      edit(key: key('知能103'), _destroy: '1')

      text = RereadWarning.for(@curriculum.reload.document, @curriculum.pages.first)

      assert_includes text, '科目: 知能101 科目知能101'
      assert_includes text, '科目「'
    end

    test '人が確認した科目の承認の印は外れ、あとで注記を外しても、その科目の承認は戻らない' do
      read
      ApprovalNotes.add(@curriculum, 'scope' => 'category', 'category' => 'core', 'text' => '承認が要る',
                                     'source_page' => 'PDF3ページ')
      assert course('知能101')['requires_approval']
      assert course('知能101')['approval_by_note']

      edit(key: key('知能101'), confirmed: true)
      assert_nil course('知能101')['approval_by_note']
      assert course('知能101')['requires_approval'], '確認しても承認の関門は外れない(安全側のまま)'

      @curriculum.with_lock do
        document = @curriculum.document.deep_dup
        note = document['approval_notes'].first
        ApprovalNotes::Removal.retract(document, note)
        @curriculum.update!(document: document)
      end

      assert course('知能101')['requires_approval'], '人が確認した科目の承認が、注記の削除に巻き込まれて外れた'
      assert_not course('知能103')['requires_approval'], '確認していない科目は、注記の削除で戻る'
    end
  end
end

