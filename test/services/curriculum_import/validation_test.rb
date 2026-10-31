# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  class ValidationTest < ActiveSupport::TestCase
    REAL_DOCUMENT = Rails.root.join('config/curricula/intelligent_informatics/2024.json')

    GARBAGE = [nil, 'x', 5, {}, [1], [[]], -1].freeze

    # ---- 人工の、検査にすべて通る文書。壊すときはここから1か所だけ変える ----

    def course(number, name, category, **fields)
      { 'key' => "course_#{number}", 'number' => number, 'name' => name, 'credits' => 2, 'category' => category,
        'required' => false, 'language' => nil, 'roles' => [], 'source' => 'handbook', 'source_page' => 'PDF3ページ',
        'review_reason' => nil, 'requires_approval' => false, 'selectable' => true }.merge(fields.stringify_keys)
    end

    def rule(id, type, **fields)
      { 'id' => id, 'type' => type, 'label' => "規則#{id}", 'source_page' => 'PDF3ページ' }.merge(fields.stringify_keys)
    end

    def row(id, categories, check_ids, required, **fields)
      { 'id' => id, 'name' => "行#{id}", 'subtitle' => nil, 'required_credits' => required, 'required_label' => nil,
        'categories' => categories, 'check_ids' => check_ids,
        'credits_from_check' => false }.merge(fields.stringify_keys)
    end

    def base_document
      { 'format_version' => 2, 'department' => 'sample', 'admission_year' => 2024, 'title' => '見本',
        'categories' => base_categories, 'courses' => base_courses, 'rules' => base_rules, 'display' => base_display }
    end

    def base_categories
      [['humanities', '人文系', true], ['english', '英語', true], ['required_core', 'コア必修', true],
       ['fusion', '工学融合', true], ['excluded', '算入対象外', false]].map do |key, label, counts|
        { 'key' => key, 'label' => label, 'counts_toward_total' => counts }
      end
    end

    def base_courses
      [course('人101', '哲学', 'humanities', roles: ['role_a']), course('人102', '倫理', 'humanities', roles: ['role_b']),
       course('人103', '歴史', 'humanities'), course('外101', '英語Ⅰ', 'english'), course('外102', '英語Ⅱ', 'english'),
       course('知能101', 'プログラミング', 'required_core', required: true),
       course('知能102', '離散数学', 'required_core', required: true),
       course('機械991', '熱力学', 'fusion'), course('機械992', '流体力学', 'fusion'),
       course('情01', '情報科学演習', 'excluded', selectable: false)]
    end

    def base_rules
      categories = %w[humanities english required_core fusion]
      [rule('humanities', 'credit_sum', categories: ['humanities'], required_credits: 4),
       rule('english', 'credit_sum', categories: ['english'], required_credits: 2),
       rule('path_rule', 'one_of_paths', paths: [['role_a'], ['role_b']]),
       rule('core', 'all_required', expected_course_count: 2, required_credits: 4,
                                    required_categories: ['required_core']),
       rule('fusion_provider', 'grouped_max', category: 'fusion', group_by: 'number_prefix', required_credits: 4),
       rule('total', 'credit_sum', categories: categories, required_credits: 14),
       rule('excluded_category', 'exclude', category: 'excluded', reason: '算入対象外')]
    end

    def base_display
      { 'total_credits' => 14,
        'groups' => [{ 'id' => 'common', 'title' => '1. 共通教育', 'required_credits' => 6,
                       'rows' => [row('humanities', ['humanities'], ['humanities'], 4),
                                  row('english', ['english'], ['english'], 2)] },
                     { 'id' => 'required', 'title' => '2. 必修', 'required_credits' => 4, 'check_id' => 'core',
                       'rows' => [row('required_core', ['required_core'], ['core'], 4)] },
                     { 'id' => 'elective', 'title' => '3. 選択', 'required_credits' => 4,
                       'rows' => [row('fusion', ['fusion'], ['fusion_provider'], 4, credits_from_check: true)] }] }
    end

    # base_document を複製して、ブロックで壊す。
    def broken(&)
      base_document.deep_dup.tap(&)
    end

    def findings_for(subject, pages: [])
      subject = Validation.new(subject, pages: pages) if subject.is_a?(Hash)
      subject.call
    end

    def assert_reason(fragment, subject, blocking: nil, scope: nil, pages: [])
      found = findings_for(subject, pages: pages).select { |finding| finding[:reason].include?(fragment) }

      assert_predicate found, :any?, "「#{fragment}」を含む理由が無い: #{findings_for(subject, pages: pages).pluck(:reason)}"
      unless blocking.nil?
        assert(found.any? do |finding|
          finding[:blocking] == blocking
        end, "blocking が #{blocking} の指摘が無い: #{found}")
      end
      assert(found.any? { |finding| finding[:scope] == scope }, "scope が #{scope} の指摘が無い: #{found}") if scope
      found
    end

    def assert_blocking(fragment, subject, **)
      assert_reason(fragment, subject, blocking: true, **)
    end

    def assert_warning(fragment, subject, **)
      found = assert_reason(fragment, subject, blocking: false, **)
      assert(found.none? { |finding| finding[:blocking] }, "警告のはずが公開を止める: #{found}")
    end

    def assert_quiet(subject, pages: [])
      assert_empty findings_for(subject, pages: pages)
    end

    # ---- 基準 ----

    test '人工の基準文書は Catalogue に読め、何も指摘されない' do
      assert_nothing_raised { GraduationAssessment::Catalogue.new(base_document) }
      assert_quiet base_document
      assert_not_predicate Validation.new(base_document), :blocking?
    end

    test '実物の2024年度の便覧は公開を止めず、区分の食い違いの印2件だけが残る' do
      document = JSON.parse(REAL_DOCUMENT.read)
      validation = Validation.new(document)

      assert_not_predicate validation, :blocking?
      # 知能301(総合実験)と工共214(プログラミングⅡ)は、必修が選択の番号帯に入る正しい例外。人が見る印にとどめる。
      assert_equal %w[informatics_integrated_experiment programming_2], validation.call.pluck(:target).sort
      assert_equal [%i[course]], [validation.call.pluck(:scope).uniq]
      assert(validation.call.none? { |finding| finding[:blocking] })
    end

    test '結果は scope・target・reason・blocking を持つ' do
      result = findings_for(broken { |d| d['courses'][0]['category'] = 'nowhere' }).first

      assert_equal %i[scope target reason blocking], result.keys
      assert_equal :course, result[:scope]
      assert_equal 'course_人101', result[:target]
    end

    # ---- 科目 ----

    test '科目番号の重複を出し、公開を止める' do
      document = broken { |d| d['courses'] << course('人101', '重複した哲学', 'humanities', key: 'dup') }

      assert_blocking '同じ科目番号', document, scope: :course
      assert_raises(ArgumentError) { GraduationAssessment::Catalogue.new(document) }
    end

    test '科目の key の重複と欠けを出し、公開を止める' do
      assert_blocking('key「course_人101」の科目が2件', broken do |d|
        d['courses'] << course('人199', 'x', 'humanities', key: 'course_人101')
      end)
      assert_blocking('科目に key がありません', broken { |d| d['courses'][0].delete('key') })
    end

    test '全角や空白の違いだけの同じ番号は、警告にとどめる' do
      assert_warning('綴りが違うだけ', broken { |d| d['courses'] << course('人１０１', '哲学(全角)', 'humanities') })
    end

    test '分類表にあって提供科目表にない科目を出す' do
      document = broken { |d| d['courses'] << course(nil, '特別講義', 'humanities', key: 'special') }

      assert_warning '提供科目表に行がない', document, scope: :course
    end

    test '番号の無い科目でも、review_reason があれば学生に要確認と出るので問題にしない' do
      document = broken do |d|
        d['courses'] << course(nil, '特別講義', 'humanities', key: 'special', credits: nil, review_reason: '分類表のみに記載')
      end

      assert_quiet document
    end

    test '番号を読めない科目は、その区分に接頭辞で数える規則があるときだけ出す' do
      assert_warning('接頭辞と数字に分けて読めません', broken { |d| d['courses'] << course('機械9-1', '融合', 'fusion') })
      assert_quiet(broken { |d| d['courses'] << course('人27-1', '枝番の科目', 'humanities') })
    end

    test '区分が空の科目も、review_reason があれば学生に要確認と出るので止めない' do
      assert_quiet(broken { |d| d['courses'][0].merge!('category' => nil, 'review_reason' => '分類表に無い') })
    end

    test '区分が categories に無い科目は、どの行にも出ないので公開を止める' do
      assert_blocking('区分「nowhere」が categories にありません', broken { |d| d['courses'][0]['category'] = 'nowhere' })
      assert_blocking('categories にありません', broken { |d| d['courses'][0]['category'] = nil })
    end

    test '単位数が読めていない科目を出す' do
      assert_warning('単位数', broken { |d| d['courses'][0]['credits'] = nil })
      assert_warning('単位数', broken { |d| d['courses'][0]['credits'] = 0 })
    end

    test '出典の無い科目を出す' do
      assert_warning('出典(source_page)がありません', broken { |d| d['courses'][0]['source_page'] = '' })
    end

    test '番号から推定した区分と食い違う科目を出し、確認済みの科目は出さない' do
      document = broken do |d|
        d['courses'] += [course('機械993', '誤読', 'required_core', key: 'odd'),
                         course('機械994', '融合Ⅲ', 'fusion'), course('機械995', '融合Ⅳ', 'fusion')]
      end

      assert_warning '区分の取り違えでないか', document, scope: :course
      document['courses'].find { |c| c['key'] == 'odd' }['confirmed'] = true

      assert_empty(findings_for(document).select { |finding| finding[:target] == 'odd' })
    end

    # ---- 規則の形 ----

    def rule_in(document, id)
      document['rules'].find { |candidate| candidate['id'] == id }
    end

    test '既知の型は、必要な欄が欠けていれば公開を止める' do
      # all_of は最上位に置けない(下の入れ子のテストで見る)。
      Validation::Input::FIELD_KINDS.except('all_of').each do |type, fields|
        fields.each_key do |field|
          document = broken do |d|
            d['rules'] << rule("sample_#{type}", type, **sample_fields(type)).except(field)
          end
          found = findings_for(document).select { |f| f[:target] == "sample_#{type}" && f[:blocking] }

          assert_predicate found, :any?, "#{type} の #{field} が欠けても止まらない"
          assert_includes found.first[:reason], field
        end
      end
    end

    test '必要な欄が、どんな型の値に化けても、検査は落ちずに公開を止める' do
      Validation::Input::FIELD_KINDS.each do |type, fields|
        fields.each do |field, kind|
          GARBAGE.each do |value|
            document = broken do |d|
              d['rules'] << rule("sample_#{type}", type, **sample_fields(type)).merge(field => value)
            end
            validation = Validation.new(document)

            assert_nothing_raised { validation.call }
            # 最上位の all_of は置けない型で警告にとどまる。空の経路([[]])だけの paths は形としては読める(警告)。
            # 5 は数の欄に、'x' は文字の欄に、正しい値。
            valid = (value == 5 && %i[number count].include?(kind)) || (value == 'x' && kind == :text)
            next if type == 'all_of' || valid || (type == 'one_of_paths' && value == [[]])

            assert_predicate validation, :blocking?, "#{type}.#{field} = #{value.inspect}"
          end
        end
      end
    end

    def sample_fields(type)
      { 'credit_sum' => { categories: ['humanities'], required_credits: 2 },
        'all_required' => { expected_course_count: 2, required_credits: 4, required_categories: ['required_core'] },
        'one_of_paths' => { paths: [['role_a']] },
        'grouped_max' => { category: 'fusion', group_by: 'number_prefix', required_credits: 2 },
        'any_of' => { options: [{ 'type' => 'credit_sum', 'categories' => ['english'], 'required_credits' => 2 }] },
        'all_of' => { conditions: [] }, 'cap' => { category: 'humanities', credits: 2 },
        'exclude' => { category: 'excluded', reason: '対象外' } }.fetch(type)
    end

    test '欄の形が違う規則(paths が配列でない、経路が配列でない)は公開を止める' do
      assert_blocking('必要な欄が無いか、形が違います: paths', broken { |d| rule_in(d, 'path_rule')['paths'] = nil })
      assert_blocking('paths', broken { |d| rule_in(d, 'path_rule')['paths'] = [nil, ['role_a']] })
      assert_blocking('required_credits', broken { |d| rule_in(d, 'humanities')['required_credits'] = '4' })
    end

    test 'paths が空、または空の経路を含む one_of_paths を出す' do
      assert_warning('paths が空', broken { |d| rule_in(d, 'path_rule')['paths'] = [] })
      assert_warning('空の経路', broken { |d| rule_in(d, 'path_rule')['paths'] = [[]] })
      assert_warning('空の経路', broken { |d| rule_in(d, 'path_rule')['paths'] = [['role_a'], []] })
    end

    test 'expected_course_count や required_credits が0の all_required は公開を止める' do
      assert_blocking('必修の科目数が0以下', broken { |d| rule_in(d, 'core')['expected_course_count'] = 0 })
      assert_blocking('必修の単位が0以下', broken { |d| rule_in(d, 'core')['required_credits'] = 0 })
    end

    test '必修の科目が1つも無い all_required を出す' do
      document = broken { |d| d['courses'].each { |c| c['required'] = false } }

      assert_warning '必修の科目が科目表に1つもありません', document
    end

    test 'all_required の required_categories が空なら公開を止める' do
      assert_blocking('required_categories が空', broken { |d| rule_in(d, 'core')['required_categories'] = [] })
    end

    test 'categories が空の credit_sum を出す' do
      assert_warning('区分(categories)が空', broken { |d| rule_in(d, 'humanities')['categories'] = [] })
    end

    test '必要単位が0以下の credit_sum は、常に充足になるので公開を止める' do
      assert_blocking('常に充足', broken { |d| rule_in(d, 'humanities')['required_credits'] = 0 })
    end

    test 'categories に無い区分を指す規則は公開を止める(入れ子も、cap・exclude も)' do
      assert_blocking('区分を指しています: ghost', broken { |d| rule_in(d, 'humanities')['categories'] = ['ghost'] })
      assert_blocking('ghost', broken { |d| rule_in(d, 'fusion_provider')['category'] = 'ghost' })
      assert_blocking('ghost', broken { |d| rule_in(d, 'excluded_category')['category'] = 'ghost' })
      nested = { 'type' => 'credit_sum', 'categories' => ['ghost'], 'required_credits' => 2 }
      assert_blocking('ghost', broken { |d| d['rules'] << rule('either', 'any_of', options: [nested]) })
    end

    test 'source_page の無い規則を出す' do
      assert_warning('出典(source_page)がありません', broken { |d| rule_in(d, 'humanities').delete('source_page') })
    end

    test 'id や label の無い規則は公開を止める' do
      assert_blocking('規則に id がありません', broken { |d| rule_in(d, 'humanities').delete('id') })
      assert_blocking('規則に label がありません', broken { |d| rule_in(d, 'humanities').delete('label') })
    end

    test '規則の id の重複は公開を止める' do
      assert_blocking('id「humanities」が2件', broken do |d|
        d['rules'] << rule('humanities', 'credit_sum', categories: ['english'], required_credits: 2)
      end)
    end

    test '解釈できない型や置けない位置の型は、要確認になるので警告にとどめる' do
      assert_warning('解釈できません', broken { |d| d['rules'] << rule('mystery', 'mystery') })
      assert_warning('置けません', broken { |d| d['rules'] << rule('lonely', 'all_of', conditions: []) })
      assert_warning('type がありません', broken { |d| d['rules'] << rule('typeless', nil) })
    end

    test 'any_of・all_of の入れ子の規則も検める' do
      nested = { 'type' => 'credit_sum', 'categories' => ['english'] }
      document = broken { |d| d['rules'] << rule('either', 'any_of', options: [nested]) }

      assert_blocking '必要な欄が無いか、形が違います: required_credits', document
      assert_warning('options が空', broken { |d| d['rules'] << rule('either', 'any_of', options: []) })
      empty_all_of = { 'type' => 'all_of', 'conditions' => [] }
      assert_warning('conditions が空', broken { |d| d['rules'] << rule('either', 'any_of', options: [empty_all_of]) })
      lacking = { 'type' => 'all_of' }
      assert_blocking('必要な欄が無いか、形が違います: conditions', broken do |d|
        d['rules'] << rule('either', 'any_of', options: [lacking])
      end)
    end

    test 'grouped_max の group_by が3つの形のどれでもなければ公開を止める' do
      assert_blocking('group_by は number_prefix', broken { |d| rule_in(d, 'fusion_provider')['group_by'] = 'provider' })
      assert_blocking('group_by は number_prefix', broken { |d| rule_in(d, 'fusion_provider')['group_by'] = 'field:' })
      assert_quiet(broken { |d| rule_in(d, 'fusion_provider')['group_by'] = 'number_prefix_hundreds' })
    end

    test 'grouped_max の field: が指す欄に値のある科目が無ければ出す' do
      assert_warning('値のある科目が', broken { |d| rule_in(d, 'fusion_provider')['group_by'] = 'field:language' })
      document = broken do |d|
        rule_in(d, 'fusion_provider')['group_by'] = 'field:language'
        d['courses'].select { |c| c['category'] == 'fusion' }.each { |c| c['language'] = '英語' }
      end

      assert_quiet document
    end

    test 'exclude の number_prefix が空、または正規化前の表記なら公開を止める' do
      ['', '知 能', '知能　', 'Ｃ', nil, 5].each do |prefix|
        document = broken do |d|
          d['rules'] << rule('own', 'exclude', category: 'fusion', reason: '自コース', number_prefix: prefix)
        end

        assert_blocking 'number_prefix', document
        assert_raises(ArgumentError) { GraduationAssessment::Catalogue.new(document) }
      end
      assert_quiet(broken do |d|
        d['rules'] << rule('own', 'exclude', category: 'fusion', reason: '自コース', number_prefix: '知能')
      end)
    end

    test 'exclude に reason が無ければ公開を止める' do
      assert_blocking('reason', broken { |d| rule_in(d, 'excluded_category').delete('reason') })
      assert_blocking('reason', broken { |d| rule_in(d, 'excluded_category')['reason'] = ' ' })
    end

    test 'cap の credits が負・非数・無限なら公開を止める' do
      [-1, 'abc', nil, Float::INFINITY, Float::NAN].each do |credits|
        document = broken { |d| d['rules'] << rule('cap1', 'cap', category: 'humanities', credits: credits) }

        assert_blocking 'credits', document
      end
      assert_quiet(broken { |d| d['rules'] << rule('cap1', 'cap', category: 'humanities', credits: 0) })
    end

    # ---- 役割 ----

    test '規則が名指しする役割を、どの科目も持っていなければ出す' do
      document = broken { |d| rule_in(d, 'path_rule')['paths'] = [['role_a'], ['role_ghost']] }

      assert_warning '役割(role_ghost)を持つ科目が、科目表にありません', document
    end

    # 役割は判定に効かない(必須の役割は one_of_paths からだけ作られる)ので、参照が無くても公開は止めない。
    test '科目に付いているのに、どの規則も参照しない役割は、要件が落ちた疑いとして警告にとどめる' do
      document = broken { |d| d['courses'][2]['roles'] = ['role_lost'] }

      assert_warning '役割「role_lost」は科目に付いていますが、どの規則も参照していません', document
      assert_nothing_raised { GraduationAssessment::Catalogue.new(document) }
    end

    test '宣言されているだけで、科目も規則も使わない役割は警告にとどめる' do
      document = broken { |d| d['roles'] = [{ 'key' => 'role_a' }, { 'key' => 'role_b' }, { 'key' => 'role_idle' }] }

      assert_warning '役割「role_idle」は宣言されていますが', document
    end

    # ---- 規則と科目表の突き合わせ ----

    test '必修の単位合計が all_required の required_credits と違えば出す' do
      assert_warning('必修の単位合計(4)が、規則の必要単位(6)と違います', broken { |d| rule_in(d, 'core')['required_credits'] = 6 })
    end

    test '必修の科目数が規則と違えば出す' do
      assert_warning('必修の科目数(2)が、規則の科目数(3)と違います', broken { |d| rule_in(d, 'core')['expected_course_count'] = 3 })
    end

    test '必修の科目が必修の区分の外にあれば出す' do
      assert_warning('必修の区分(required_core)の外にあります', broken { |d| d['courses'][0]['required'] = true })
    end

    test '科目表のすべての科目を修得しても必要単位に届かない credit_sum を出す' do
      assert_warning('必要な8単位に届きません', broken { |d| rule_in(d, 'english')['required_credits'] = 8 })
    end

    test '数える区分に科目が1つも無い規則を出す' do
      document = broken { |d| d['courses'].reject! { |c| c['category'] == 'humanities' } }

      assert_warning '数える区分(humanities)に科目が1つもありません', document
    end

    test '総単位に数えない区分に、丸ごと算入から外す exclude 規則が無ければ公開を止める' do
      assert_blocking('exclude 規則がありません', broken { |d| d['rules'].reject! { |r| r['id'] == 'excluded_category' } })
      # 接頭辞つきの exclude は区分の一部しか外さないので、覆ったことにしない。
      document = broken { |d| rule_in(d, 'excluded_category')['number_prefix'] = '情' }

      assert_blocking 'exclude 規則がありません', document
    end

    test '総単位の規則が数える区分が、総単位に数える区分と違えば出す' do
      assert_warning('足りない区分: fusion', broken { |d| rule_in(d, 'total')['categories'] -= ['fusion'] })
      assert_warning('余分な区分: excluded', broken { |d| rule_in(d, 'total')['categories'] += ['excluded'] })
      assert_warning('総単位の判定が規則にありません', broken { |d| rule_in(d, 'total')['required_credits'] = 13 })
    end

    # ---- 画面の表 ----

    test 'check_ids が指す規則がなければ出し、公開を止める' do
      document = broken { |d| d['display']['groups'][0]['rows'][0]['check_ids'] = %w[humanities vanished] }

      assert_blocking '規則が見つかりません: vanished', document, scope: :display
    end

    test '章の check_id・小計の check_ids と row_ids が指す先がなければ公開を止める' do
      assert_blocking('規則が見つかりません: vanished', broken { |d| d['display']['groups'][1]['check_id'] = 'vanished' })
      subtotal = { 'id' => 'sub', 'name' => '小計', 'required_credits' => 4, 'row_ids' => %w[fusion gone],
                   'check_ids' => ['core'] }
      assert_blocking('指す行が見つかりません: gone', broken { |d| d['display']['subtotals'] = [subtotal] })
      assert_blocking('規則が見つかりません: vanished', broken do |d|
        d['display']['subtotals'] = [subtotal.merge('row_ids' => [], 'check_ids' => ['vanished'])]
      end)
    end

    test 'check_ids が cap や exclude の id を指していても、Check が無いので止める' do
      assert_blocking('規則が見つかりません: excluded_category', broken do |d|
        d['display']['groups'][0]['rows'][0]['check_ids'] = ['excluded_category']
      end)
    end

    # Task 16 のレビューで見つかった穴。DraftMerge.withdraw は規則だけを外し、display が指す check_id を残す。
    test '読み直しで規則だけが外れて display に残った参照を、公開の前に止める' do
      document = base_document
      DraftMerge.withdraw(document, { 'rules' => %w[humanities] }, 3)
      assert_blocking '規則が見つかりません: humanities', document, scope: :display
    end

    test 'credits_from_check の行は categories が空配列でもよい(指す規則が数える区分を出すものとして扱う)' do
      document = broken { |d| d['display']['groups'][2]['rows'][0]['categories'] = [] }

      assert_quiet document
      assert_nothing_raised { GraduationAssessment::Catalogue.new(document) }
      strict = broken do |d|
        d['display']['groups'][2]['rows'][0]['categories'] = []
        d['display']['groups'][2]['rows'][0]['credits_from_check'] = false
      end

      assert_blocking '画面のどの行にも出てきません', strict
    end

    # 欄が無いと、計画表が row[:categories].include? を呼んで落ちる。Catalogue は通すので、ここで止める。
    test '行の categories が無い・配列でないなら、credits_from_check の行でも公開を止める' do
      [:absent, nil, 'fusion'].each do |value|
        document = broken do |d|
          row = d['display']['groups'][2]['rows'][0]
          value == :absent ? row.delete('categories') : row['categories'] = value
        end

        assert_blocking 'categories が配列ではありません', document, scope: :display
      end
    end

    # 学生は任意の算入区分に自分で科目を入れられるので、科目表に無い区分が満たせないわけではない。止めずに知らせる。
    test '科目が1つも無い区分が、必要単位のある行に出ていれば警告する(止めない)' do
      document = broken { |d| d['courses'].reject! { |c| c['category'] == 'english' } }

      assert_warning '区分「英語」(english)に科目が1つもありません', document, scope: :display
      assert_not_predicate Validation.new(document), :blocking?
    end

    test '必要単位の無い行の、科目が無い区分は、学生が自由に入れる区分として許す' do
      document = broken do |d|
        d['categories'] << { 'key' => 'free', 'label' => '自由', 'counts_toward_total' => true }
        d['display']['groups'][2]['rows'] << row('free', ['free'], ['fusion_provider'], nil, required_label: '内数')
        rule_in(d, 'total')['categories'] << 'free'
      end

      assert_quiet document
    end

    test '要件表が内数を明記した自由科目の行(必要単位あり)も、公開を止めない' do
      document = broken do |d|
        d['categories'] << { 'key' => 'free', 'label' => '自由', 'counts_toward_total' => true }
        d['display']['groups'][2]['rows'] << row('free', ['free'], ['fusion_provider'], 11)
        rule_in(d, 'total')['categories'] << 'free'
      end

      assert_warning '区分「自由」(free)に科目が1つもありません', document
      assert_not_predicate Validation.new(document), :blocking?
    end

    test '行が categories に無い区分を指していれば公開を止める' do
      assert_blocking('区分を指しています: ghost', broken { |d| d['display']['groups'][0]['rows'][0]['categories'] = ['ghost'] })
    end

    test 'どの行にも出てこない区分があれば出す(公開を止める)' do
      document = broken { |d| d['display']['groups'][2]['rows'].clear }
      result = Validation.new(document)

      assert_reason '画面のどの行にも出てきません', result
      assert_predicate result, :blocking?
    end

    test 'excluded はどの行に出てこなくても止めない' do
      assert_not_predicate Validation.new(base_document), :blocking?
      shown = base_document['display']['groups'].flat_map { |group| group['rows'] }.flat_map { |row| row['categories'] }

      assert_not_includes shown, 'excluded'
    end

    test '区分ごとの必要単位の合計が卒業総単位を超えていたら出す' do
      assert_blocking('章の必要単位の合計(17)が、卒業算入の総単位(14)を超えて',
                      broken { |d| d['display']['groups'][0]['required_credits'] = 9 })
      assert_warning('区分ごとの必要単位の合計(16)が、卒業算入の総単位(14)を超えて',
                     broken { |d| rule_in(d, 'humanities')['required_credits'] = 14 })
    end

    test '総単位を低く読んだ便覧は、総単位の規則が充足と答えるので公開を止める' do
      document = JSON.parse(REAL_DOCUMENT.read)
      document['display']['total_credits'] -= 4
      document['rules'].find { |r| r['id'] == 'total' }['required_credits'] -= 4
      result = Validation.new(document)

      assert_blocking('章の必要単位の合計(130)が、卒業算入の総単位(126)を超えて', result)
      assert_predicate result, :blocking?
    end

    # 総単位に数えない区分だけの章(教職科目など)は、総単位とは別に積める。
    test '総単位に数えない区分だけの章は、章の合計に入れない' do
      document = broken do |d|
        d['categories'] << { 'key' => 'teaching', 'label' => '教職', 'counts_toward_total' => false }
        d['rules'] << rule('teaching_exclude', 'exclude', category: 'teaching', reason: '教職は算入対象外')
        d['courses'] << course('教01', '教職入門', 'teaching')
        d['display']['groups'] << { 'id' => 'teaching', 'title' => '4. 教職', 'required_credits' => 20,
                                    'rows' => [row('teaching', ['teaching'], [], 20)] }
      end

      assert_quiet document
    end

    test '総単位が章の合計より大きいのは正当なので出さない' do
      document = broken do |d|
        d['display']['total_credits'] = 18
        rule_in(d, 'total')['required_credits'] = 18
      end

      assert_quiet document
    end

    test '章・行の必要単位が、指す規則の必要単位と違えば出す' do
      assert_warning('必要単位(5)が、規則「humanities」の必要単位(4)と違います',
                     broken { |d| d['display']['groups'][0]['rows'][0]['required_credits'] = 5 })
      assert_warning('章「required」の必要単位(5)', broken { |d| d['display']['groups'][1]['required_credits'] = 5 })
      subtotal = { 'id' => 'sub', 'name' => '小計', 'required_credits' => 5, 'row_ids' => ['fusion'],
                   'check_ids' => ['fusion_provider'] }
      document = broken { |d| d['display']['subtotals'] = [subtotal] }

      assert_warning('小計「sub」の必要単位(5)が、規則「fusion_provider」の必要単位(4)', document)
    end

    test '総単位が読めていなければ公開を止める' do
      assert_blocking('display.total_credits', broken { |d| d['display'].delete('total_credits') })
    end

    # ---- ページと承認の注記 ----

    def page(number, kind: 'courses', status: 'read', text: '本文', warnings: nil)
      { 'page' => number, 'kind' => kind, 'status' => status, 'error' => nil, 'text' => text,
        'warnings' => warnings }.compact
    end

    test 'テキストが空のページがあるのに承認の注記が1つも無い便覧を出す' do
      pages = [page(3, text: nil), page(4, text: '  '), page(5)]

      assert_warning '承認の注記が1つもありません', base_document, pages: pages, scope: :document
      assert_equal ['PDF3・4ページ'], findings_for(base_document, pages: pages).pluck(:target)
    end

    test '承認の注記が1つでもあれば、テキストの空のページを出さない' do
      document = broken do |d|
        d['approval_notes'] =
          [{ 'scope' => 'category', 'category' => 'humanities', 'text' => '承認', 'source_page' => 'PDF3ページ' }]
      end

      assert_quiet document, pages: [page(3, text: nil)]
    end

    test '読まないページ・まだ読んでいないページのテキストの空は、承認の見落としとして出さない' do
      assert_empty(findings_for(base_document, pages: [page(1, kind: 'skip', text: nil)]).select do |f|
        f[:reason].include?('承認の注記')
      end)
      assert_empty(findings_for(base_document, pages: [page(3, status: 'pending', text: nil)]).select do |f|
        f[:reason].include?('承認の注記')
      end)
    end

    test '読む種別なのに読めていないページを出す' do
      pages = [page(3, status: 'failed'), page(4, status: 'pending'), page(5, kind: 'skip', status: 'pending')]

      assert_warning '読み取れていないページ', base_document, pages: pages
      assert_equal ['PDF3・4ページ'], findings_for(base_document, pages: pages).pluck(:target)
    end

    test '承認に触れる警告がページに残っているのに、注記も承認の科目も無ければ出す' do
      pages = [page(3, warnings: ['このページの文字に「承認」とありますが、承認が要る科目として読めた科目がありません。'])]

      assert_warning '承認の注記も、承認が必要な科目もありません', base_document, pages: pages
      assert_quiet broken { |d| d['courses'][0]['requires_approval'] = true }, pages: pages
    end

    test 'Validation.for は下書きの document と pages を渡す' do
      curriculum = Curriculum.new(slug: 'sample', admission_year: 2024, document: base_document,
                                  pages: [page(3, text: nil)])

      assert_warning '承認の注記が1つもありません', Validation.for(curriculum)
    end

    # ---- 壊れた形・最後の網 ----

    test '形が壊れた文書でも例外にせず、公開を止める' do
      documents = [nil, [], 'text', {}, { 'courses' => 'x', 'rules' => [1, 'a'], 'display' => [] },
                   { 'courses' => [nil, 3], 'categories' => { 'a' => 1 },
                     'display' => { 'groups' => [{ 'rows' => 'x' }] } },
                   base_document.merge('rules' => [{ 'type' => 'any_of', 'id' => 'a', 'label' => 'a',
                                                     'options' => 'x' }])]
      documents.each do |document|
        validation = Validation.new(document)

        assert_nothing_raised { validation.call }
        assert_predicate validation, :blocking?, document.inspect
      end
    end

    test 'courses が無い文書は、読める理由で公開を止める' do
      assert_blocking('courses がありません', broken { |d| d.delete('courses') })
    end

    test '形の問題は、読めない部分を空として検査を続けるうえで、公開を止める' do
      assert_blocking('ハッシュでない要素が1件', broken { |d| d['courses'] << 'oops' })
      assert_blocking('rules は配列でなければ', broken { |d| d['rules'] = 'x' })
      assert_blocking('display はハッシュでなければ', broken { |d| d['display'] = [] })
    end

    test '検査が拾わなくても、本物の読み込みが落ちる便覧は、その理由で公開を止める' do
      # 行の name が無い。Catalogue が display の形として弾く(この検査は名前を見ていない)。
      document = broken { |d| d['display']['groups'][0]['rows'][0].delete('name') }

      assert_blocking '便覧として読み込めない、または判定できません', document, scope: :document
      assert_blocking 'name がありません', document
    end

    # ---- 文書の骨組み ----

    test '科目が1つも無い便覧は、他の検査が何も見ないまま通るので、公開を止める' do
      assert_blocking '科目が1つもありません', broken { |d| d['courses'] = [] }, scope: :course
    end

    test '規則が1つも無い便覧は、公開を止める' do
      assert_blocking '判定の規則が1つもありません', broken { |d| d['rules'] = [] }, scope: :rule
    end

    test '規則があるのに display が無い便覧は、画面が開けないので公開を止める' do
      assert_blocking '画面の要件表(display)がありません', broken { |d| d.delete('display') }, scope: :display
    end

    test '骨組みが揃っていれば、骨組みの指摘は出ない' do
      assert_empty(findings_for(base_document).select { |finding| finding[:target].in?(%w[courses rules display]) })
    end

    test '警告だけの文書は公開を止めない' do
      document = broken { |d| d['courses'][0]['source_page'] = '' }

      assert_predicate Validation.new(document).call, :any?
      assert_not_predicate Validation.new(document), :blocking?
    end
  end
end

