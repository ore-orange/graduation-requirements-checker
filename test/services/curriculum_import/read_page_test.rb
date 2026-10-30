# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  class ReadPageTest < ActiveSupport::TestCase
    # 実際の読み取り(外部API)は呼ばない。ページごとに決めた答えを返し、呼ばれた引数を覚える窓口の代役。
    class StubReader
      attr_reader :calls

      def initialize(requirements: {}, courses: {}, error: nil)
        @requirements = requirements
        @courses = courses
        @error = error
        @calls = []
      end

      def read_requirements(text:, image_path:)
        @calls << [:requirements, { text: text, image_path: image_path }]
        raise @error if @error

        @requirements.fetch(text)
      end

      def read_courses(text:, image_path:, categories:, roles:)
        @calls << [:courses, { text: text, image_path: image_path, categories: categories, roles: roles }]
        raise @error if @error

        @courses.fetch(text)
      end
    end

    CATEGORIES = [{ 'key' => 'course_required', 'label' => 'コース専門必修', 'counts_toward_total' => true },
                  { 'key' => 'natural', 'label' => '自然系', 'counts_toward_total' => true }].freeze
    BLANK_PAGE = { 'status' => 'pending', 'error' => nil }.freeze
    PAGES = [{ 'page' => 1, 'kind' => 'skip', 'text' => '表紙' },
             { 'page' => 3, 'kind' => 'requirements', 'text' => '要件' },
             { 'page' => 4, 'kind' => 'requirements', 'text' => '要件その2' },
             { 'page' => 9, 'kind' => 'courses', 'text' => '科目' },
             { 'page' => 10, 'kind' => 'courses', 'text' => '科目その2' }].freeze
    ROLES = [{ 'key' => 'calculus_st_1', 'label' => '微分積分学ＳＴⅠ' }].freeze

    def requirements_answer(rule_id: 'common_total', categories: CATEGORIES, roles: ROLES, detail: nil, total: 130)
      { 'categories' => categories, 'roles' => roles,
        'rules' => [{ 'id' => rule_id, 'type' => 'credit_sum', 'label' => '共通教育', 'categories' => ['natural'],
                      'required_credits' => 30, 'detail' => detail }],
        'display' => { 'total_credits' => total,
                       'groups' => [{ 'id' => "g_#{rule_id}", 'title' => '1. 共通教育', 'required_credits' => 30,
                                      'check_id' => rule_id,
                                      'rows' => [{ 'id' => "r_#{rule_id}", 'name' => '自然系', 'subtitle' => nil,
                                                   'required_credits' => 30, 'required_label' => nil,
                                                   'categories' => ['natural'], 'check_ids' => [rule_id],
                                                   'credits_from_check' => false }] }] } }
    end

    def course_row(number, name: "科目#{number}", category: 'course_required', requires_approval: false, roles: [])
      { 'number' => number, 'name' => name, 'credits' => 2, 'category' => category, 'required' => true,
        'requires_approval' => requires_approval, 'language' => nil, 'review_reason' => nil, 'roles' => roles }
    end

    setup do
      @curriculum = Curriculum.create!(
        slug: 'intelligent_informatics', admission_year: 2025, faculty_name: '工学部', department_name: '工学科 知能情報コース',
        source_filename: 'handbook.pdf',
        pages: PAGES.map { |page| BLANK_PAGE.merge(page) }
      )
      FileUtils.mkdir_p(@curriculum.images_dir)
      [3, 4, 9, 10].each { |page| File.binwrite(@curriculum.images_dir.join("p#{page}.png"), "\x89PNG".b) }
    end

    teardown { FileUtils.rm_rf(@curriculum.images_dir) }

    def reader(courses: { '科目' => { 'courses' => [course_row('知能101'), course_row('知能103')] } }, **)
      StubReader.new(requirements: { '要件' => requirements_answer, '要件その2' => requirements_answer(rule_id: 'total_2') },
                     courses: courses, **)
    end

    def read(page, with: reader)
      ReadPage.new(@curriculum, reader: with).call(page)
    end

    def document = @curriculum.reload.document

    def page_entry(number) = @curriculum.reload.pages.find { |page| page['page'] == number }

    def page_status(number) = page_entry(number)['status']

    def courses = document['courses']

    def read_second_requirements_page(detail)
      answer = requirements_answer(rule_id: 'total_2', detail: detail)
      read(4, with: StubReader.new(requirements: { '要件その2' => answer }))
    end

    def confirm_course(number)
      @curriculum.update!(document: document.merge(
        'courses' => courses.map { |course| course['number'] == number ? course.merge('confirmed' => true) : course }
      ))
    end

    def confirmed?(number) = courses.find { |course| course['number'] == number }&.dig('confirmed') == true

    test '要件表のページを読むと区分と規則と表示が入る' do
      assert read(3)

      assert_equal %w[common_total], document['rules'].pluck('id')
      assert_equal %w[course_required natural], document['categories'].pluck('key')
      assert_equal 130, document['display']['total_credits']
      assert_equal %w[g_common_total], document['display']['groups'].pluck('id')
      assert_equal 'read', page_status(3)
      assert_nil page_entry(3)['error']
    end

    test '役割は document の roles に溜まり、2ページ目で同じ key を足しても重ならない' do
      read(3)
      read(4)

      assert_equal ['calculus_st_1'], document['roles'].pluck('key')
      assert_equal '微分積分学ＳＴⅠ', document['roles'].first['label']
    end

    test '役割も区分も無い要件表なら roles の欄は作らない' do
      reader = StubReader.new(requirements: { '要件' => requirements_answer(roles: []) })

      assert read(3, with: reader)
      assert_not document.key?('roles')
    end

    test '断片の統合: 文書の見出しと、規則の source_page と、出典が入る' do
      read(3)

      assert_equal 2, document['format_version']
      assert_equal 'intelligent_informatics', document['department']
      assert_equal 2025, document['admission_year']
      assert_equal 'PDF3ページ', document['rules'].first['source_page']
      source = document['sources'].first
      assert_equal 'handbook_2025', source['id']
      assert_includes source['pages'], '3'
    end

    test '複数の要件表のページは足し合わされ、表示の章は読んだ順に並ぶ' do
      read(3)
      read(4)

      assert_equal %w[common_total total_2], document['rules'].pluck('id')
      assert_equal %w[g_common_total g_total_2], document['display']['groups'].pluck('id')
    end

    test '別のページと規則の id がぶつかったら、そのページの分を付け替え、参照も追う' do
      other = StubReader.new(requirements: { '要件' => requirements_answer, '要件その2' => requirements_answer })
      read(3, with: other)
      read(4, with: other)

      assert_equal %w[common_total common_total_p4], document['rules'].pluck('id')
      group = document['display']['groups'].last
      assert_equal 'common_total_p4', group['check_id']
      assert_equal ['common_total_p4'], group['rows'].first['check_ids']
      assert_equal %w[g_common_total g_common_total_p4], document['display']['groups'].pluck('id')
    end

    test '同じ要件表のページを読み直しても、そのページの分は二重にならない' do
      read(3)
      read(3)

      assert_equal %w[common_total], document['rules'].pluck('id')
      assert_equal 1, document['display']['groups'].size
      assert_equal %w[course_required natural], document['categories'].pluck('key')
    end

    test '総単位が別のページの値と食い違ったら、先の値を残して警告を残す' do
      other = StubReader.new(requirements: { '要件' => requirements_answer(total: 130),
                                             '要件その2' => requirements_answer(rule_id: 'total_2', total: 124) })
      read(3, with: other)
      read(4, with: other)

      assert_equal 130, document['display']['total_credits']
      assert_match(/124/, page_entry(4)['warnings'].join)
    end

    test '科目表のページを読むと科目が足され、区分と役割が読み取りに渡る' do
      read(3)
      stub = reader
      assert read(9, with: stub)

      assert_equal 2, courses.size
      assert_equal 'read', page_status(9)
      kind, args = stub.calls.last
      assert_equal :courses, kind
      assert_equal CATEGORIES, args[:categories]
      assert_equal ROLES, args[:roles]
      assert_equal @curriculum.images_dir.join('p9.png').to_s, args[:image_path].to_s
      assert_equal '科目', args[:text]
    end

    test '科目の断片の統合: key・source・source_page・selectable が入る' do
      read(3)
      read(9)

      course = courses.find { |entry| entry['number'] == '知能101' }
      assert_equal 'course_知能101', course['key']
      assert_equal 'handbook_2025', course['source']
      assert_equal 'PDF9ページ', course['source_page']
      assert_equal true, course['selectable']
      assert_equal '科目知能101', course['name']
      assert_equal %w[handbook_2025], document['sources'].pluck('id')
    end

    test '統合した下書きは、そのまま Catalogue(判定が読む形)として読める' do
      read(3)
      read(9)

      catalogue = GraduationAssessment::Catalogue.new(document)

      assert_equal %w[course_required natural], catalogue.category_keys
      assert_equal 2, catalogue.courses.size
      assert_equal 'course_知能101', catalogue.course_for('知能101')['key']
    end

    test '番号が別のページの科目と同じなら上書きせず、別の key で残す' do
      read(3)
      read(9)
      second = reader(courses: { '科目その2' => { 'courses' => [course_row('知能101', name: '別の行')] } })
      read(10, with: second)

      same_number = courses.select { |course| course['number'] == '知能101' }
      assert_equal 2, same_number.size
      assert_equal 2, same_number.pluck('key').uniq.size
      assert_equal %w[科目知能101 別の行], same_number.pluck('name')
    end

    test '番号の無い科目にも、ぶつからない key が付く' do
      read(3)
      rows = [course_row(nil, name: '分類表だけの科目'), course_row(nil, name: 'もう1つ')]
      read(9, with: reader(courses: { '科目' => { 'courses' => rows } }))

      assert_equal 2, courses.pluck('key').uniq.size
      assert(courses.all? { |course| course['key'].present? })
    end

    test '要件表を1ページも読む前に科目表を読むと、そのページだけ failed になり落ちない' do
      stub = reader

      assert_not read(9, with: stub)
      assert_equal 'failed', page_status(9)
      assert_match(/要件表/, page_entry(9)['error'])
      assert_empty stub.calls, '区分が無いのに読み取りを呼んではいけない'
      assert_nil document['courses']
    end

    test '読み取りが落ちてもそのページだけ failed になり、読めたページは残る' do
      read(3)
      failing = reader(error: CurriculumReader::Error.new('読み取りを呼び出せませんでした'))

      assert_not read(9, with: failing)
      assert_equal 'failed', page_status(9)
      assert_includes page_entry(9)['error'], '読み取りを呼び出せませんでした'
      assert_equal 'read', page_status(3)
      assert_equal %w[common_total], document['rules'].pluck('id')
    end

    test '失敗したページを読み直して成功すれば、error は消える' do
      read(3)
      read(9, with: reader(error: CurriculumReader::Error.new('だめ')))
      assert_equal 'failed', page_status(9)

      assert read(9)
      assert_equal 'read', page_status(9)
      assert_nil page_entry(9)['error']
    end

    test 'ページ画像が無ければ読み取りを呼ばずに failed にする' do
      read(3)
      FileUtils.rm_f(@curriculum.images_dir.join('p9.png'))
      stub = reader

      assert_not read(9, with: stub)
      assert_equal 'failed', page_status(9)
      assert_empty(stub.calls.pluck(0).select { |kind| kind == :courses })
    end

    test '読み取り直しても、確認済みにした科目は消えず、二重にもならない' do
      read(3)
      read(9)
      confirm_course('知能103')

      assert read(9)

      assert confirmed?('知能103')
      assert_equal %w[知能101 知能103], courses.pluck('number').sort
    end

    test '読み直しで、確認していない科目は読み取りの最新の結果に入れ替わる' do
      read(3)
      read(9)
      confirm_course('知能103')
      changed = reader(courses: { '科目' => { 'courses' => [course_row('知能103'), course_row('知能105')] } })

      read(9, with: changed)

      assert_equal %w[知能103 知能105], courses.pluck('number').sort
    end

    test 'kind が skip のページは読まず、状態も変えない' do
      stub = reader

      assert_not read(1, with: stub)
      assert_empty stub.calls
      assert_equal 'pending', page_status(1)
    end

    test '存在しないページは false' do
      assert_not read(99)
    end

    test '読み取り中に別の人が確認した科目を、保存で消さない' do
      read(3)
      read(9)
      slow = reader(courses: { '科目その2' => { 'courses' => [course_row('知能201')] } })
      # 読み取りの最中(HTTPの待ち)に、別のリクエストが知能101を確認済みにした状況
      other = Curriculum.find(@curriculum.id)
      slow.define_singleton_method(:read_courses) do |text:, **|
        other.update!(document: other.document.merge(
          'courses' => other.document['courses'].map { |c| c['number'] == '知能101' ? c.merge('confirmed' => true) : c }
        ))
        @courses.fetch(text)
      end

      assert read(10, with: slow)

      assert confirmed?('知能101')
      assert_includes courses.pluck('number'), '知能201'
    end

    test '読み取りの結果は、渡した答えを書き換えない(答えを使い回しても壊れない)' do
      answer = requirements_answer
      stub = StubReader.new(requirements: { '要件' => answer })
      read(3, with: stub)

      assert_nil answer['rules'].first['source_page']
    end

    # --- 承認の注記がページを跨ぐ場合 ---

    test '区分の承認の注記は、別のページの科目の requires_approval を真にする(要件表が先)' do
      read(3, with: StubReader.new(requirements: { '要件' => requirements_answer(detail: '自然系の科目は履修に指導教員の承認が必要') }))
      rows = [course_row('自101', category: 'natural'), course_row('知能101')]
      read(9, with: reader(courses: { '科目' => { 'courses' => rows } }))

      approvals = courses.to_h { |course| [course['number'], course['requires_approval']] }
      assert_equal({ '自101' => true, '知能101' => false }, approvals)
    end

    test '科目表が先でも、あとで要件表を読めば反映される' do
      read(3)
      read(9, with: reader(courses: { '科目' => { 'courses' => [course_row('自101', category: 'natural')] } }))
      assert_equal false, courses.first['requires_approval']

      read_second_requirements_page('自然系は指導教員の承認を得ること')

      assert_equal true, courses.first['requires_approval']
    end

    test '承認が反映されたとき、確認済みだった科目は確認を外して見直しに戻す' do
      read(3)
      read(9, with: reader(courses: { '科目' => { 'courses' => [course_row('自101', category: 'natural')] } }))
      confirm_course('自101')

      read_second_requirements_page('承認が必要')

      assert_equal true, courses.first['requires_approval']
      assert_not confirmed?('自101')
    end

    test '承認の注記のある要件表を読み直して注記が消えても、いったん立てた真は戻さない' do
      read(3, with: StubReader.new(requirements: { '要件' => requirements_answer(detail: '承認が必要') }))
      read(9, with: reader(courses: { '科目' => { 'courses' => [course_row('自101', category: 'natural')] } }))
      assert_equal true, courses.first['requires_approval']

      read(3)

      assert_equal true, courses.first['requires_approval'], '偽に戻すと、水増しの方向に倒れる'
      assert_empty document['approval_notes'].to_a
    end

    test '区分が分からない承認の注記は、反映せず、そのページの警告に残す' do
      answer = requirements_answer
      answer['rules'].first['categories'] = []
      answer['rules'].first['detail'] = '履修には指導教員の承認が必要'
      answer['display']['groups'].first['rows'].first['categories'] = []
      read(3, with: StubReader.new(requirements: { '要件' => answer }))

      assert_match(/承認/, page_entry(3)['warnings'].join)
      assert_equal 'read', page_status(3)
    end

    test 'ページ単位の承認の注記は、そのページから読んだ科目すべてに反映される' do
      read(3)
      read(9)
      read(10, with: reader(courses: { '科目その2' => { 'courses' => [course_row('知能201')] } }))

      ApprovalNotes.add(@curriculum, { 'scope' => 'page', 'page' => 9, 'text' => '※このページの科目は承認が必要' })

      approvals = courses.to_h { |course| [course['number'], course['requires_approval']] }
      assert_equal({ '知能101' => true, '知能103' => true, '知能201' => false }, approvals)
    end

    test '科目表のページの文字に承認とあるのに、どの科目にも印が付かなければ警告する' do
      @curriculum.pages = @curriculum.pages.map { |page| page['page'] == 9 ? page.merge('text' => '※承認が必要') : page }
      @curriculum.save!
      read(3)

      stub = StubReader.new(courses: { '※承認が必要' => { 'courses' => [course_row('知能101')] } })
      read(9, with: stub)

      assert_match(/承認/, page_entry(9)['warnings'].join)
    end

    test '科目に印が付いているなら、承認の文字があっても警告しない' do
      @curriculum.pages = @curriculum.pages.map { |page| page['page'] == 9 ? page.merge('text' => '※承認が必要') : page }
      @curriculum.save!
      read(3)

      stub = StubReader.new(courses: { '※承認が必要' => { 'courses' => [course_row('知能101', requires_approval: true)] } })
      read(9, with: stub)

      assert_empty page_entry(9)['warnings'].to_a
    end
  end
end

