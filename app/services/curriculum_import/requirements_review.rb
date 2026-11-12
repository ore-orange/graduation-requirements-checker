# frozen_string_literal: true

module CurriculumImport
  # 要件表の確認画面が見せるもの。document を画面が引ける形に整え、突き合わせの結果(Validation)を結びつける。
  #
  # 下書きの document は AI が書いたものを人が直したもので、欄が壊れていることがある(Validation::Input が読める形にする)。
  # 画面がそれで落ちると、壊れた下書きを直す画面そのものが開けなくなるので、画面は Input を通して読む。
  class RequirementsReview
    SCOPE_NAMES = { course: '科目', rule: '規則', display: '画面の表', document: '文書全体' }.freeze
    # 決まりが「何を数えるか」を書く欄。行の区分が空のとき、指す決まりの区分で代える。
    CATEGORY_FIELDS = %w[category categories].freeze

    # 保存できなかった送信の、送られたままの入力(欄の名前 → 値)。画面を同じ入力で開き直すために持つ。
    # 画面のフォームごとに、持ち主を見分ける(要件表のフォームは form=requirements を送る)。
    class Submission
      def initialize(pairs)
        @values = pairs.group_by(&:first).transform_values { |entries| entries.map(&:last) }
      end

      def main_form? = @values['form'] == ['requirements']

      delegate :key?, to: :@values

      def value(name) = @values[name]&.last

      def values(name) = @values.fetch(name, [])
    end

    attr_reader :curriculum, :problems

    delegate :categories, :rules, :groups, :subtotals, :display, :courses, to: :input

    # submission は、保存できなかった送信の入力。problems と touched は RequirementsEdit の結果。
    def initialize(curriculum, submission: nil, problems: [], touched: [])
      @curriculum = curriculum
      @submission = submission
      @problems = problems
      @touched = touched
    end

    # 入力欄の値。保存できなかった送信の入力があれば、それを残す(1つの打ち間違いで、打った全部を失わせない)。
    def field_value(name, default)
      @submission&.key?(name) ? @submission.value(name) : default
    end

    # チェックの箱の状態。送信が要件表のフォームからなら、そこで入っていた箱だけが入っている(入っていない箱は外れている)。
    def field_checked?(name, value, default)
      @submission&.main_form? ? @submission.values(name).include?(value) : default
    end

    # チップに出す区分。保存できなかった送信があれば、そのとき送られていた区分を出す
    # (1つの打ち間違いで、選び直しをさせない)。「＋」で足した区分も、送られていればチップになる。
    def chosen_categories(name, default)
      return Array(default).grep(String) unless @submission&.main_form?

      (@submission.values("#{name}[]") + [@submission.value(adder_name(name))]).grep(String).compact_blank.uniq
    end

    # categories → add][categories。画面の欄の名前の作り方と揃える(RequirementsReviewHelper#adder_name)。
    def adder_name(name) = name.sub(/\[([^\[\]]+)\]\z/) { "[add][#{Regexp.last_match(1)}]" }

    def problems_for(kind, id) = problems.select { |problem| problem.kind == kind && problem.id == id.to_s }

    # 値を変えた項目と、問題があった項目は、「直す」を開いたまま見せる(どこを直したか・どこが問題かを隠さない)。
    def open?(kind, id) = @touched.include?([kind, id.to_s])

    # 読み取った要件表が何も無い下書き(まだ読んでいない)は、確認するものが無い。突き合わせの「何も無い」を並べない。
    def started?
      categories.any? || rules.any? || groups.any? || read_requirements_page?
    end

    def findings
      @findings ||= Validation.for(curriculum).call
    end

    def blocking?
      findings.any? { |finding| finding[:blocking] }
    end

    def blocking_findings = findings.select { |finding| finding[:blocking] }

    def warning_findings = findings.reject { |finding| finding[:blocking] }

    # 項目(規則の id・章や行の id)に結びつく突き合わせの結果。表の行の下に出す。
    def findings_for(scope, target)
      findings.select { |finding| finding[:scope] == scope && finding[:target] == target.to_s }
    end

    def scope_name(scope) = SCOPE_NAMES.fetch(scope, scope.to_s)

    # 画面を開いたときの中身の指紋。保存のときに送り返され、開いたあとに中身が変わっていないかを確かめる。
    def revision = RequirementsEdit.revision(curriculum.document)

    def cards = @cards ||= Annotations.cards(curriculum.document, curriculum.pages)

    delegate :category_label, to: :input

    delegate :category_keys, :uncounted_category_keys, to: :input

    def course_count(category) = input.courses_in(category).size

    def rule_ids = input.rules.pluck('id')

    # 役割(経路が名指しするキー)を持つ科目の名前。規則が名指しする役割に科目が無いと、その規則は必ず要確認になる。
    def role_names(role) = courses.select { |course| Array(course['roles']).include?(role) }.pluck('name')

    # 経路の欄に出す役割の選択肢。科目が持つ役割に加えて、いま規則の経路が名指ししている役割も入れる
    # (科目が1つも無い役割を選択肢から外すと、画面から送り返すだけでその経路が消えてしまう)。
    def known_roles
      (courses.flat_map { |course| Array(course['roles']) } +
       rules.flat_map { |rule| Array(rule['paths']).flatten }).grep(String).uniq.sort
    end

    def rows_of(group) = Array(group['rows']).grep(Hash)

    # 入れ子を持つ規則の欄は、1ページにつき1か所だけが出す(同じ名前のパラメータを2回送らないため)。
    # 先に呼んだ場所だけが true を受け取る。画面1枚ぶんの覚え書きなので、この presenter が持つ。
    def claim_rule_box?(id)
      @claimed_rule_boxes ||= Set.new
      @claimed_rule_boxes.add?(id).present?
    end

    # ---- ツリー(設計書 項目4・6・10) ----

    def tree = @tree ||= Tree.new(input)

    delegate :nodes_of, :loose_subtotals, to: :tree

    # 章・枠の下に出す決まり。その決まりの欄は、ここで初めて出す1か所だけが持つ。
    def rules_under(ids) = claim(find_rules(ids))

    # 行の下に出す決まり。行が指す決まりと、この行の区分に掛かる算入上限(設計書 項目4)。
    def rules_under_row(row) = claim(find_rules(row['check_ids']) + tree.caps_of(row))

    # 卒業に必要な総単位に当たる決まり。「卒業に必要な総単位」の枠に、その数字と一緒に出す(設計書 項目6)。
    # 見つけ方は Validation::DisplayChecks#total_rule と同じ(必要単位が総単位と同じ credit_sum)。
    def total_rule = @total_rule ||= claim(find_total_rule).first

    # 算入しない科目。要件ではなく除外なので、章・行のツリーには混ぜず、専用の枠に出す(設計書 項目6)。
    def exclude_rules = claim(rules.select { |rule| rule['type'] == 'exclude' })

    # 提供コースの選択肢(設計書 項目9)。便覧は提供コースの名前を持たないので、科目番号の接頭辞で表す。
    # 選択肢は科目表に出てくる接頭辞から作り、当たる科目を例示する(接頭辞だけでは、何に当たるか画面から分からない)。
    # いま除外が名指ししている接頭辞も入れる(選択肢から外すと、送り返すだけでその条件が消えてしまう)。
    def number_prefixes
      @number_prefixes ||= begin
        found = courses.group_by { |course| CourseNumber.prefix(course['number']) }.except(nil)
        named = rules.filter_map { |rule| rule['number_prefix'] if rule['number_prefix'].is_a?(String) }
        (found.keys + named).uniq.map { |prefix| [prefix, found.fetch(prefix, []).pluck('name')] }
      end
    end

    # 名指しの科目番号が、科目表のどの科目に当たるか。当たらない番号は、科目表に無いことが分かるように出す。
    def named_courses(numbers)
      Array(numbers).grep(String).map do |number|
        wanted = CourseNumber.normalize(number)
        course = courses.find { |item| CourseNumber.normalize(item['number']) == wanted }
        [number, course&.dig('name')]
      end
    end

    # ここまでのどの枠も出さなかった決まり。読み取り直後にどこからも指されていない決まりも、黙って隠さない
    # (設計書 項目6)。ツリー・除外の枠をすべて描いたあとに呼ぶこと。
    def unclaimed_rules = claim(rules)

    # 行が対象にしている区分の科目を、区分ごとに。区分が空の行(単位を決まりから取る行)は、
    # 指す決まりが数える区分で代える(DisplayChecks#shown_categories と同じ読み方)。
    def courses_of_row(row)
      categories_of_row(row).uniq.map { |key| [key, input.courses_in(key)] }
    end

    def course_count_of_row(row) = courses_of_row(row).sum { |_, courses| courses.size }

    # 「◯単位以下」に出す数。中にある算入上限の決まりが1つのときだけ数で出す
    # (2つ以上あるときは、それぞれの決まりの箱で読む)。
    def upper_limit(shown_rules)
      caps = shown_rules.select { |rule| rule['type'] == 'cap' }
      caps.one? ? caps.first['credits'] : nil
    end

    # 行の名前。小計がまとめている行を、id ではなく人が読める名前で出すために引く。
    def row_names(ids)
      Array.wrap(ids).grep(String).map do |id|
        input.rows.find { |row| row['id'] == id }&.dig('name').presence || "#{id}(行が見つかりません)"
      end
    end

    # 決まりを結びつける先の選択肢。人は id を打たず、章・枠・行を名前で選ぶ(設計書 項目5)。
    # 値は "種類:id"。章の check_id は単数なので、すでに決まりを持つ章は選べない(設計書 項目6)。
    def link_targets
      groups.filter_map { |group| ["章: #{group['title']}", "group:#{group['id']}"] if group['check_id'].blank? } +
        subtotals.map { |subtotal| ["枠: #{subtotal['name']}", "subtotal:#{subtotal['id']}"] } +
        groups.flat_map do |group|
          rows_of(group).map { |row| ["行: #{group['title']} / #{row['name']}", "row:#{row['id']}"] }
        end
    end

    def removed_items
      Array(curriculum.document.is_a?(Hash) ? curriculum.document[DraftMerge::REMOVED] : nil).grep(Hash)
    end

    private

    def input
      @input ||= Validation::Input.new(curriculum.document, curriculum.pages)
    end

    # 同じ決まりを2か所に出さない。id の重複も落とす(1つの行が同じ id を2回指していても、欄は1組)。
    def claim(candidates)
      candidates.uniq { |rule| rule['id'] }.select { |rule| claim_rule_box?(rule['id']) }
    end

    def find_rules(ids)
      Array.wrap(ids).grep(String).filter_map { |id| rules.find { |rule| rule['id'] == id } }
    end

    def find_total_rule
      total = display['total_credits']
      return [] unless total.is_a?(Numeric)

      [rules.find do |rule|
        rule['type'] == 'credit_sum' && rule['required_credits'] == total && linked_rule_ids.exclude?(rule['id'])
      end].compact
    end

    # 章・行・小計のどれかが指している決まりの id。
    def linked_rule_ids
      @linked_rule_ids ||= (groups.flat_map { |group| Array.wrap(group['check_id']) } +
                            input.rows.flat_map { |row| Array.wrap(row['check_ids']) } +
                            subtotals.flat_map { |subtotal| Array.wrap(subtotal['check_ids']) }).grep(String).uniq
    end

    def categories_of_row(row)
      own = Array(row['categories']).grep(String)
      return own if own.any?

      find_rules(row['check_ids']).flat_map { |rule| CATEGORY_FIELDS.flat_map { |f| Array(rule[f]).grep(String) } }
    end

    # 規則も区分も表も無くても、読み取りが終わっていれば(承認の警告や欠けは)見せる。
    def read_requirements_page?
      curriculum.pages.any? { |page| page['status'] == 'read' && page['kind'] == 'requirements' }
    end
  end
end

