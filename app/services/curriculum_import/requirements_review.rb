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

    delegate :category_label, :rule_name, to: :input

    delegate :category_keys, :uncounted_category_keys, to: :input

    def course_count(category) = input.courses_in(category).size

    def rule_ids = input.rules.pluck('id')

    # 区分の科目番号パターンの候補。既にパターンを持つ区分の除外は CategoryInference#suggestions が行う。
    def pattern_suggestions_for(category_key) = pattern_suggestions.fetch(category_key, [])

    # 候補を採用したとき、科目表から外れる科目([全体の件数, うち確認済み, うち手で足した])。採用の操作と同じ判定で数える。
    def adoption_impact(category_key)
      @adoption_impacts ||= {}
      @adoption_impacts[category_key] ||= begin
        dropped = CoursePrune.dropping(adopted_view(category_key), drop_confirmed: true, only: [category_key])
        [dropped.size, dropped.count { |course| CourseEdit.confirmed?(course) },
         dropped.count { |course| course['added_by_hand'] == true }]
      end
    end

    # 決まりが名指ししている出典。2024年度は27個の決まりに2種類しかないので、節に1度だけ出す(設計書 項目4)。
    def source_pages = @source_pages ||= rules.filter_map { |rule| rule['source_page'].presence }.uniq

    # 出典がばらばらなら、節にまとめても「この数字はPDFのどこか」を追えない。そのときは決まりの横にも出す。
    SOURCE_PAGE_LIMIT = 3

    def source_per_rule? = source_pages.size > SOURCE_PAGE_LIMIT

    # 経路に出す科目(設計書 項目3-1)。役割キーは画面に出さず、科目の「番号 名前」で見せる。
    # 画面が送り返すのは科目の key で、保存(NestedCoercion#paths)が役割に直す。
    # 科目が1つも無い役割は、そのキーのまま返す(選択肢から外すと、送り返すだけでその経路が消えてしまう)。
    # 1つの役割を複数の科目が持つことがある(便覧が「次のどれかを修得」とまとめている科目の束)。
    # 先頭だけを出すと、ほかの科目でも満たせることが画面から分からないので、件数を添える。
    def path_courses(path)
      Array(path).grep(String).map do |role|
        found = courses.select { |item| Array(item['roles']).include?(role) }
        next [role, "#{role}(科目表にありません)"] if found.empty?

        [found.first['key'], course_label(found.first) + (found.one? ? '' : " ほか#{found.size - 1}件")]
      end
    end

    # チップに出す科目。保存できなかった送信があれば、そのとき送られていた科目を出す
    # (1つの打ち間違いで、選び直した組を全部失わせない)。「＋」で足した科目も、送られていればチップになる。
    #
    # 画面は科目の key を送り、文書は役割キーを持つ。どちらも courses の key か役割のどちらかなので、
    # ここで科目に引き直してから並べる。
    def chosen_path_courses(name, path)
      return path_courses(path) unless @submission&.main_form?

      keys = (@submission.values("#{name}[]") + [@submission.value(adder_name(name))]).grep(String).compact_blank.uniq
      keys.map { |key| [key, course_for_chip(key)] }
    end

    def course_for_chip(key)
      course = courses.find { |item| item['key'] == key } ||
               courses.find { |item| Array(item['roles']).include?(key) }
      course ? course_label(course) : "#{key}(科目表にありません)"
    end

    def course_label(course) = "#{course['number']} #{course['name']}".strip

    # 経路に足せる科目。区分で絞る(484科目を1つの選択肢に並べない)。選んである科目は出さない。
    def course_options(category, chosen)
      input.courses_in(category).reject { |course| chosen.include?(course['key']) }
           .map { |course| [course_label(course), course['key']] }
    end

    # 「＋ 科目を足す」に出す区分。その決まりを指す行が対象にしている区分だけに絞る。
    #
    # 2024年度は484科目あり、全部の区分の科目を経路の数だけ描くと、画面が1MBを超える(重さの予算)。
    # 指定科目の系列は、その行が数える区分の中にある(日本語表現法入門→日本語、微分積分学→専門基礎)。
    # 行が分からない決まりだけ、科目のある区分すべてを出す。
    def path_category_options(rule)
      keys = categories_for_rule(rule['id'])
      keys = category_keys if keys.empty?
      keys.filter_map { |key| [category_label(key), key] if input.courses_in(key).any? }
    end

    # その決まりを指している行が、対象にしている区分。
    def categories_for_rule(id)
      input.rows.select { |row| Array(row['check_ids']).grep(String).include?(id) }
           .flat_map { |row| Array(row['categories']).grep(String) }.uniq
    end

    def rows_of(group) = Array(group['rows']).grep(Hash)

    # 入れ子を持つ規則の欄は、1ページにつき1か所だけが出す(同じ名前のパラメータを2回送らないため)。
    # 先に呼んだ場所だけが true を受け取る。画面1枚ぶんの覚え書きなので、この presenter が持つ。
    def claim_rule_box?(id)
      @claimed_rule_boxes ||= Set.new
      @claimed_rule_boxes.add?(id).present?
    end

    # ---- 持ち主と同じことを言っている決まり(設計書 項目1) ----

    def mirror = @mirror ||= Mirror.new(input)

    # rules のうち、持ち主(行・章・枠・総単位の枠)の欄が言い尽くしているもの。画面は、この決まりの箱を描かず、
    # 名前と注記だけを持ち主の「…」に出す。欄の名前は箱に出すときと同じなので、保存側は何も変わらない。
    # 指摘・入力の問題が付いた決まりは隠さない(隠すと、指摘を出す場所が画面から消える)。
    def hidden_rule(owner_kind, owner, rules)
      Array(rules).find { |rule| mirror.duplicate?(rule, owner_kind, owner, blocked: blocked_rule?(rule)) }
    end

    def blocked_rule?(rule)
      id = rule['id']
      findings_for(:rule, id).any? || problems_for('rule', id).any?
    end

    # この行の単位を持っている章・枠([種類, 名前, 単位])。行が自分の数字の決まりを持っていないときだけ出す。
    #
    # 章や枠が先に取った決まりを、その中の行も指していることがある。その行の required_credits は判定が
    # 使っていない数字なので、入力欄のまま残すと「直しても判定が動かない」落とし穴がその行に残る(設計書 項目1-2)。
    def credits_holder(row) = holders[row['id']]

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

    def pattern_suggestions
      @pattern_suggestions ||= CategoryInference.new(input.courses).suggestions(input.categories)
    end

    # その区分に候補を入れた文書(件数を数えるための見せかけ。保存はしない)。
    def adopted_view(category_key)
      patterns = pattern_suggestions_for(category_key)
      adopted = input.categories.map do |category|
        category['key'] == category_key ? category.merge('number_patterns' => patterns) : category
      end
      # rules も渡す。CourseFilter が grouped_max の欄を規則から読むので、無いと保護が効かず、実際に外れる件数と食い違う。
      { 'categories' => adopted, 'courses' => input.courses, 'rules' => input.document['rules'] }
    end

    def input
      @input ||= Validation::Input.new(curriculum.document, curriculum.pages)
    end

    # 行 id → その行の単位を持っている章・枠。描く順ではなく、ツリーの親子から決まる(画面が呼ぶ順に依らない)。
    def holders
      @holders ||= groups.each_with_index.with_object({}) do |(group, index), map|
        holders_in(group, index, map)
      end
    end

    def holders_in(group, index, map)
      frames = tree.nodes_of(index).filter_map { |node, _| node if node.is_a?(Tree::Frame) }
      rows_of(group).each do |row|
        frame = frames.find { |item| item.rows.any? { |candidate| candidate['id'] == row['id'] } }
        holder = holder_for(Array(row['check_ids']).grep(String), frame, group)
        map[row['id']] = holder if holder
      end
    end

    # 枠が先、次に章(画面が決まりの箱を描く順と同じ)。
    def holder_for(ids, frame, group)
      return frame_holder(frame) if frame_holds?(frame, ids)
      return unless group['check_id'].is_a?(String) && ids.include?(group['check_id'])

      ['章', group['title'], group['required_credits']]
    end

    def frame_holds?(frame, ids)
      frame.present? && Array(frame.subtotal['check_ids']).grep(String).intersect?(ids)
    end

    def frame_holder(frame) = ['枠', frame.subtotal['name'], frame.subtotal['required_credits']]

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

