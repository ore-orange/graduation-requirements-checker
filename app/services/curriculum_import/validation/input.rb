# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 検査の入力。便覧の document と、取り込みのページ一覧(pages)を、検査が型を気にせず読める形にする。
    #
    # 下書きの document は AI が書いたものを人が直したもので、欄が無い・配列でない・要素がハッシュでないことがある。
    # 検査が NoMethodError で落ちると確認画面そのものが開けなくなるので、読めない形は空として扱い、
    # そのこと自体を shape_problems に残す(公開は止める。黙って空と見なすと、規則や科目が消えたまま通る)。
    class Input
      include Values

      # 規則1つ。入れ子の規則は、親の中での場所(target)と、そこに置ける型(allowed)を持つ。
      # target は突き合わせ用(id か、親の場所)。人に見せる名前は Input#node_name が作る(親と何番目かを parent・position から引く)。
      Node = Struct.new(:rule, :target, :allowed, :top, :parent, :position)
      # 規則を指している行・章・小計。名前の無い規則を、「どの行の規則か」で呼ぶための持ち主。
      # [持ち主の一覧, 規則を指す欄, 名前の欄, 名前を作るメソッド]。行・章・小計の順に探す。
      OWNERS = [[:rows, 'check_ids', 'name', :row_name], [:groups, 'check_id', 'title', :group_name],
                [:subtotals, 'check_ids', 'name', :subtotal_name]].freeze
      NESTED_NAMES = { 'options' => '選択肢', 'conditions' => '条件' }.freeze
      NESTING = { 'any_of' => ['options', GraduationAssessment::Rules::ANY_OF_OPTIONS],
                  'all_of' => ['conditions', GraduationAssessment::Rules::ALL_OF_CONDITIONS] }.freeze
      # 最上位に置ける型。判定を作る型に、算入を変える cap・exclude を足したもの。
      TOP_LEVEL = (GraduationAssessment::Rules::TOP_LEVEL + GraduationAssessment::Rules::ADJUSTMENTS.keys).freeze

      # 型ごとに、必須の欄とその値の種類。cap の上限と exclude の接頭辞の検めは、読み込み時に使う本物の構築に任せる
      # (同じ検査を二度書かない)。構築は reason の空白だけの文字列を通すので、reason はここでも見る。
      FIELD_KINDS = {
        'credit_sum' => { 'categories' => :keys, 'required_credits' => :number },
        'all_required' => { 'expected_course_count' => :count, 'required_credits' => :number,
                            'required_categories' => :keys },
        'one_of_paths' => { 'paths' => :paths },
        'grouped_max' => { 'category' => :text, 'group_by' => :text, 'required_credits' => :number },
        'any_of' => { 'options' => :list },
        'all_of' => { 'conditions' => :list },
        'cap' => { 'category' => :text },
        # exclude の区分は必須でない(科目番号だけの除外を書けるようにするため。設計書 項目9)。
        # 条件が1つも無い除外は、すべての科目を外してしまうので、Rules::Exclude の構築が断る(RuleShape が blocking にする)。
        'exclude' => { 'reason' => :text }
      }.freeze
      VALUE_CHECKS = { keys: :keys?, paths: :paths?, list: :list?, number: :number?, count: :count?,
                       text: :text? }.freeze

      attr_reader :document, :pages, :courses, :categories, :rules, :roles, :approval_notes, :display, :groups, :rows,
                  :subtotals, :shape_problems

      def initialize(document, pages)
        @document = document.is_a?(Hash) ? document : {}
        @pages = pages.is_a?(Array) ? pages.grep(Hash) : []
        @shape_problems = []
        load_lists
        nodes # 入れ子の形の問題も、検査の前にここで拾っておく
      end

      def category_keys
        @category_keys ||= categories.pluck('key').select { |key| key.is_a?(String) && !key.empty? }
      end

      # 卒業の総単位に数えない区分。その科目は exclude 規則が算入から外す。
      def uncounted_category_keys
        @uncounted_category_keys ||= categories.select { |category| category['counts_toward_total'] == false }
                                               .pluck('key')
      end

      def counted_category_keys
        category_keys - uncounted_category_keys
      end

      def category_label(key)
        categories.find { |category| category['key'] == key }&.dig('label').presence || key
      end

      def adjustment?(rule)
        GraduationAssessment::Rules::ADJUSTMENTS.key?(rule['type'])
      end

      # 画面の check_ids が引ける規則の id。判定を作る規則だけが Check になる。
      def condition_ids
        rules.reject { |rule| adjustment?(rule) }.pluck('id').grep(String)
      end

      # 入れ子も含めたすべての規則。
      def nodes
        @nodes ||= rules.each_with_index.flat_map do |rule, index|
          walk(Node.new(rule, rule_target(rule, "rules[#{index}]"), TOP_LEVEL, true))
        end
      end

      def top_nodes
        nodes.select(&:top)
      end

      def nodes_of(type)
        nodes.select { |node| node.rule['type'] == type }
      end

      # 必須の欄が揃い、値の種類も合っている、その型の規則。他の規則・科目表との突き合わせは、これだけを相手にする
      # (欄が壊れた規則は RuleShape が止めるので、突き合わせは読めるものだけを見ればよい)。
      def well_formed_nodes_of(type)
        nodes_of(type).select { |node| missing_fields(node).empty? }
      end

      # 型が要求する欄のうち、無いもの・値の種類が違うもの。型が分からない(置けない位置の)規則は空。
      def missing_fields(node)
        fields = FIELD_KINDS[node.rule['type']]
        return [] unless fields && node.allowed.include?(node.rule['type'])

        fields.reject { |field, kind| send(VALUE_CHECKS.fetch(kind), node.rule[field]) }.keys
      end

      def courses_in(category)
        courses.select { |course| course['category'] == category }
      end

      # その区分が、科目番号のパターンを持つか。持つ区分の科目は便覧に書かず、番号で決まるので、科目0件は異常ではない。
      def patterned?(category_key)
        categories.any? { |category| category['key'] == category_key && Array(category['number_patterns']).any? }
      end

      def approval_recorded?
        approval_notes.any?
      end

      # ---- 人に見せる名前。内部の id(規則の id・行の id)を画面に出さないために、指摘の文面はここを通る ----

      # 規則の名前。label があればそれ。無ければ「持ち主の行・章の名前 + 型の和名」(どちらか片方だけのこともある)。
      def rule_name(rule)
        return rule['label'].strip if text?(rule['label'])

        type = RuleTypeNames.for(rule['type'])
        owner = owner_name(rule)
        return "#{owner}の#{type}" if owner && type

        owner || type || '名前のない規則'
      end

      # 規則1つ(入れ子も)の名前。入れ子は、親の名前を使って「…の中の条件(2つ目)」と言う。
      def node_name(node)
        return rule_name(node.rule) if node.parent.nil?

        field, number = node.position
        "#{parent_reference(node.parent.rule)}の中の#{NESTED_NAMES.fetch(field, field)}(#{number}つ目)"
      end

      # 画面の行の名前。名前の無い行は、id を出さずに名前が無いと言う。
      def row_name(row_id) = display_item_name(rows, row_id, 'name', '行', '名前のない行')

      def group_name(group_id) = display_item_name(groups, group_id, 'title', '章', '名前のない章')

      def subtotal_name(subtotal_id) = display_item_name(subtotals, subtotal_id, 'name', '小計', '名前のない小計')

      # 規則を数える区分の和名。区分に名前が無ければ、区分のキーを出すしかない。
      def category_labels(keys) = Array(keys).map { |key| category_label(key) }.join('、')

      def role_label(key)
        roles.find { |role| role['key'] == key }&.dig('label').presence || key
      end

      private

      def load_lists
        @shape_problems << [:course, 'courses', 'courses がありません'] if document['courses'].nil?
        @courses = list(document, 'courses', :course, 'courses')
        @categories = list(document, 'categories', :display, 'categories')
        @rules = list(document, 'rules', :rule, 'rules')
        @roles = list(document, 'roles', :rule, 'roles')
        @approval_notes = list(document, ApprovalNotes::KEY, :document, ApprovalNotes::KEY)
        load_display
      end

      def load_display
        value = document['display']
        @shape_problems << [:display, 'display', 'display はハッシュでなければなりません'] unless value.nil? || value.is_a?(Hash)
        @display = value.is_a?(Hash) ? value : {}
        @groups = list(display, 'groups', :display, 'display.groups')
        @subtotals = list(display, 'subtotals', :display, 'display.subtotals')
        @rows = groups.flat_map { |group| list(group, 'rows', :display, "display.groups[#{group['id']}].rows") }
      end

      # nil は「無い」として空。配列以外と、ハッシュ以外の要素は読めないので外し、形の問題として残す。
      def list(source, field, scope, name)
        value = source[field]
        return [] if value.nil?
        return not_a_list(scope, name) unless value.is_a?(Array)

        broken = value.grep_v(Hash)
        @shape_problems << [scope, name, "#{name} にハッシュでない要素が#{broken.size}件あります"] if broken.any?
        value.grep(Hash)
      end

      def not_a_list(scope, name)
        @shape_problems << [scope, name, "#{name} は配列でなければなりません"]
        []
      end

      def keys?(value)
        value.is_a?(Array) && value.all? { |key| text?(key) }
      end

      def paths?(value)
        value.is_a?(Array) && value.all? { |path| keys?(path) }
      end

      def list?(value)
        value.is_a?(Array)
      end

      def count?(value)
        value.is_a?(Integer)
      end

      def walk(node)
        nesting = NESTING[node.rule['type']]
        return [node] unless nesting

        field, allowed = nesting
        children = list(node.rule, field, :rule, "#{node.target} の #{field}")
        [node] + children.each_with_index.flat_map do |child, index|
          walk(Node.new(child, "#{node.target} の #{field}[#{index + 1}]", allowed, false, node, [field, index + 1]))
        end
      end

      def rule_target(rule, fallback)
        rule['id'].is_a?(String) && !rule['id'].empty? ? rule['id'] : fallback
      end

      def display_item_name(items, id, field, kind, nameless)
        name = items.find { |candidate| candidate['id'] == id }&.dig(field)
        text?(name) ? "#{kind}「#{name.strip}」" : nameless
      end

      def owner_name(rule)
        id = rule['id']
        return unless text?(id)

        OWNERS.each do |list, field, name_field, namer|
          owner = public_send(list).find { |candidate| Array.wrap(candidate[field]).include?(id) }
          return send(namer, owner['id']) if owner && text?(owner[name_field])
        end
        nil
      end

      # 入れ子の親の呼び方。label があれば「その名前」、無ければ持ち主の行(「行「…」」)。それも無ければ規則の名前。
      def parent_reference(rule)
        return "「#{rule['label'].strip}」" if text?(rule['label'])

        owner_name(rule) || rule_name(rule)
      end
    end
  end
end

