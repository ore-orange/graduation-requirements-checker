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
      Node = Struct.new(:rule, :target, :allowed, :top)
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
        'exclude' => { 'category' => :text, 'reason' => :text }
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
          walk(Node.new(rule, rule_name(rule, "rules[#{index}]"), TOP_LEVEL, true))
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

      def approval_recorded?
        approval_notes.any?
      end

      private

      def load_lists
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
          walk(Node.new(child, "#{node.target} の #{field}[#{index + 1}]", allowed, false))
        end
      end

      def rule_name(rule, fallback)
        rule['id'].is_a?(String) && !rule['id'].empty? ? rule['id'] : fallback
      end
    end
  end
end

