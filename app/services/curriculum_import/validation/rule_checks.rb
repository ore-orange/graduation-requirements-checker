# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 規則を、他の規則・区分・科目表と突き合わせる。設計書 §4 の 2〜4(必修の合計、規則が参照する区分)と、
    # 規則が名指しする役割、算入しない区分の見張り。
    class RuleChecks < Checks
      def run
        identities
        category_references
        unreachable_requirements
        roles
        excluded_categories
        required_courses
      end

      private

      # 最上位の規則は、id で画面の行と結ばれ、label と出典が画面に出る。id が重なると、画面は先の1つを引き、
      # 別の規則の数字を行に出す。出典が無いと、確認する人がどのページと照らせばよいか分からない。
      def identities
        input.top_nodes.each { |node| identity(node) }
        duplicate_ids
      end

      def identity(node)
        rule = node.rule
        return unless Input::TOP_LEVEL.include?(rule['type'])

        findings.blocking(:rule, node.target, '規則に id がありません。画面の行から引けません。') unless text?(rule['id'])
        if !input.adjustment?(rule) && !text?(rule['label'])
          findings.blocking(:rule, node.target, '規則に label がありません。判定の時にエラーになります。')
        end
        return if text?(rule['source_page'])

        findings.warning(:rule, node.target,
                         '規則に出典(source_page)がありません。便覧のどのページから読んだか分からず、確かめられません。')
      end

      def duplicate_ids
        input.rules.pluck('id').select { |id| text?(id) }.tally.each do |id, count|
          next if count == 1

          findings.blocking(:rule, id, "規則の id「#{id}」が#{count}件あります。画面の行は先の1件しか引けず、別の規則の数字が出ます。")
        end
      end

      # 便覧に無い区分を指す規則は、何も数えないまま不足とも充足とも言う(公開すると Catalogue が読み込みを拒む)。
      # 区分はあっても科目が1つも無ければ、その規則は必ず不足になる。取り込みの途中か、科目表の読み落とし。
      def category_references
        input.nodes.each do |node|
          referenced = referenced_categories(node.rule)
          unknown = referenced - input.category_keys
          if unknown.any?
            findings.blocking(:rule, node.target,
                              "規則が categories に無い区分を指しています: #{unknown.uniq.join('、')}。公開すると便覧を読み込めません。")
          end
          without_courses(node, referenced) if unknown.empty?
        end
      end

      def referenced_categories(rule)
        fields = %w[category categories required_categories].flat_map { |field| Array.wrap(rule[field]) }
        fields.grep(String)
      end

      def without_courses(node, referenced)
        return unless %w[credit_sum grouped_max].include?(node.rule['type'])
        return if referenced.empty? || referenced.any? { |category| input.courses_in(category).any? }

        findings.warning(:rule, node.target, "数える区分(#{referenced.join('、')})に科目が1つもありません。この規則は必ず不足になります。")
      end

      # 科目表のすべての科目を修得しても必要単位に届かない credit_sum。要件表の数字が正しいなら、科目表に読み落としがある。
      # 区分に科目が無いもの(学生が自由に入れる区分)を含む規則は、届くかどうかが科目表では決まらないので見ない。
      def unreachable_requirements
        input.well_formed_nodes_of('credit_sum').each do |node|
          rule = node.rule
          next if rule['categories'].empty?

          reachable = reachable_credits(rule['categories'])
          next if reachable.nil? || reachable >= rule['required_credits']

          required = format_number(rule['required_credits'])
          findings.warning(:rule, node.target, "科目表の該当科目をすべて修得しても#{format_number(reachable)}単位で、" \
                                               "必要な#{required}単位に届きません。科目の読み落としがないか確かめてください。")
        end
      end

      def reachable_credits(categories)
        return if categories.any? { |category| input.courses_in(category).empty? }

        counted = categories - input.uncounted_category_keys
        input.courses.select { |course| counted.include?(course['category']) }
             .sum(BigDecimal('0')) { |course| decimal(course['credits']) || BigDecimal('0') }
      end

      # 規則が名指しする役割を持つ科目が無ければ、その規則は必ず要確認になる。
      # 役割を持つ科目があるのに、どの規則も参照しないなら、その要件が規則から落ちている疑いがある。落ちた要件は、
      # 学生が満たしていなくても何も言わない。
      def roles
        held = input.courses.flat_map { |course| Array.wrap(course['roles']) }.grep(String).uniq
        named = roles_named_by_rules(held)
        (input.roles.pluck('key').grep(String) | held).each do |role|
          orphan_role(role, held) unless named.include?(role)
        end
      end

      # 規則が名指しする役割を返す。科目に無い役割は、その場で警告にする。
      def roles_named_by_rules(held)
        input.well_formed_nodes_of('one_of_paths').flat_map do |node|
          roles = node.rule['paths'].flatten.uniq
          missing = roles - held
          if missing.any?
            findings.warning(:rule, node.target, "規則が名指しする役割(#{missing.join('、')})を持つ科目が、科目表にありません。この規則は必ず要確認になります。")
          end
          roles
        end.uniq
      end

      def orphan_role(role, held)
        if held.include?(role)
          findings.blocking(:rule, role, "役割「#{role}」は科目に付いていますが、どの規則も参照していません。" \
                                         'その科目に求める要件が規則から落ちていると、満たしていない学生にも何も言いません。')
        else
          findings.warning(:rule, role, "役割「#{role}」は宣言されていますが、どの規則も科目も使っていません。")
        end
      end

      # 総単位に数えない区分の科目は、exclude 規則が算入から外す。規則が無いと、その科目の単位が他の規則に数えられる。
      def excluded_categories
        covered = input.well_formed_nodes_of('exclude').select { |node| node.top && !node.rule.key?('number_prefix') }
                       .map { |node| node.rule['category'] }
        (input.uncounted_category_keys.grep(String) - covered).each do |category|
          findings.blocking(:rule, category, "区分「#{input.category_label(category)}」は卒業の総単位に数えない" \
                                             '(counts_toward_total が false)のに、その区分の科目を丸ごと算入から外す' \
                                             'exclude 規則がありません。この区分の単位が算入されます。')
        end
      end

      # 設計書 §4 の 3。必修の科目表と、要件表の「必修N科目M単位」を突き合わせる。判定は食い違いを要確認にするが、
      # 公開の前に、どちらが誤りかを人が見られるよう理由を出す。
      def required_courses
        input.well_formed_nodes_of('all_required').each do |node|
          node.rule
          mandatory = input.courses.select { |course| course['required'] }
          if mandatory.empty?
            findings.warning(:rule, node.target, '必修の科目が科目表に1つもありません。この規則は必ず要確認になります。')
          else
            required_totals(node, mandatory)
          end
        end
      end

      def required_totals(node, mandatory)
        rule = node.rule
        credits = mandatory.sum(BigDecimal('0')) { |course| decimal(course['credits']) || BigDecimal('0') }
        if credits != BigDecimal(rule['required_credits'].to_s)
          required = format_number(rule['required_credits'])
          findings.warning(:rule, node.target, "必修の単位合計(#{format_number(credits)})が、規則の必要単位(#{required})と違います。")
        end
        if mandatory.size != rule['expected_course_count']
          findings.warning(:rule, node.target,
                           "必修の科目数(#{mandatory.size})が、規則の科目数(#{rule['expected_course_count']})と違います。")
        end
        outside_required_categories(node, mandatory)
      end

      # 必修の科目が必修の区分の外に入っていると、科目数も単位合計も合ったまま、その単位が選択の集計にも流れて二重に数えられる。
      def outside_required_categories(node, mandatory)
        allowed = node.rule['required_categories']
        outside = mandatory.reject { |course| allowed.include?(course['category']) }
        return if outside.empty?

        names = outside.map { |course| "#{course['name']}(#{course['category']})" }.join('、')
        findings.warning(:rule, node.target, "必修の科目が必修の区分(#{allowed.join('、')})の外にあります: #{names}。区分の取り違えがないか確かめてください。")
      end
    end
  end
end

