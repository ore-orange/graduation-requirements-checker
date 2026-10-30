# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 規則1つずつの形の検査。既知の型が要求する欄が揃っているか、値が「黙って充足」や落ちる判定に倒れないか。
    #
    # Catalogue は読み込み時に、重複や宛先の無い区分の参照などを弾く。ここはその先、読み込めてしまうが判定を
    # 誤らせる定義と、判定の時に落ちる定義を、公開の前に規則の名前つきで言う。
    # 区分の参照の宛先と、規則同士・科目との突き合わせは RuleChecks がする。
    class RuleShape < Checks
      Rules = GraduationAssessment::Rules
      GROUP_BY_NUMBER = GraduationAssessment::Ledger::NUMBER_GROUPERS.keys.freeze
      FIELD_GROUP = GraduationAssessment::Ledger::FIELD_GROUP

      def run
        input.nodes.each { |node| check(node) }
      end

      private

      def check(node)
        type = node.rule['type']
        return unplaceable(node, type) unless node.allowed.include?(type)

        missing = input.missing_fields(node)
        return semantics(node, type) if missing.empty?

        findings.blocking(:rule, node.target, "規則の型「#{type}」に必要な欄が無いか、形が違います: #{missing.join('、')}。" \
                                              '判定の時にエラーになります。')
      end

      # 解釈できない型・置けない位置の規則は、判定で必ず要確認になる(充足とは言わない)。確認画面で直せるよう知らせる。
      def unplaceable(node, type)
        reason = if Rules::TYPES.key?(type) || Rules::ADJUSTMENTS.key?(type)
                   "規則の型「#{type}」はこの位置には置けません"
                 elsif type.nil? || type == ''
                   '規則に type がありません'
                 else
                   "規則の型「#{type}」をこのアプリは解釈できません"
                 end
        findings.warning(:rule, node.target, "#{reason}。この規則の判定は必ず要確認になります。")
      end

      def semantics(node, type)
        case type
        when 'credit_sum' then credit_sum(node)
        when 'all_required' then all_required(node)
        when 'one_of_paths' then one_of_paths(node)
        when 'grouped_max' then grouped_max(node)
        when 'any_of', 'all_of' then children(node)
        else adjustment(node)
        end
      end

      def credit_sum(node)
        rule = node.rule
        always_satisfied(node, '必要単位') unless rule['required_credits'].positive?
        return unless rule['categories'].empty?

        findings.warning(:rule, node.target, 'credit_sum が数える区分(categories)が空です。何も数えないので、必ず不足になります。')
      end

      # 必要単位が0以下の規則は、何も修得しなくても充足になる。必修の確認(all_required)は、科目数と単位が0の定義が
      # そのまま「必修0科目をすべて修得」になる。どちらも充足に倒れるので、公開は止める。
      def always_satisfied(node, field)
        findings.blocking(:rule, node.target, "#{field}が0以下のため、何も修得しなくても常に充足になります。")
      end

      def all_required(node)
        rule = node.rule
        always_satisfied(node, '必修の科目数') unless rule['expected_course_count'].positive?
        always_satisfied(node, '必修の単位') unless rule['required_credits'].positive?
        return unless rule['required_categories'].empty?

        findings.blocking(:rule, node.target,
                          'all_required の required_categories が空です。必修の区分の取り違えを見張れず、公開すると便覧を読み込めません。')
      end

      def one_of_paths(node)
        paths = node.rule['paths']
        if paths.empty?
          findings.warning(:rule, node.target, 'paths が空です。この規則は判定できず、必ず要確認になります。')
        elsif paths.any?(&:empty?)
          findings.warning(:rule, node.target, 'paths に空の経路があります。この規則は判定できず、必ず要確認になります。')
        end
      end

      # group_by が3つの形のどれでもないと、判定の時にエラーになる。
      def grouped_max(node)
        rule = node.rule
        always_satisfied(node, '必要単位') unless rule['required_credits'].positive?
        group_by = rule['group_by']
        field = group_by.delete_prefix(FIELD_GROUP) if group_by.start_with?(FIELD_GROUP)
        if GROUP_BY_NUMBER.include?(group_by) || text?(field)
          field_without_values(node, field) if field
        else
          findings.blocking(:rule, node.target, 'group_by は number_prefix・number_prefix_hundreds・field:<欄名> の' \
                                                "どれかでなければなりません: #{group_by.inspect}。判定の時にエラーになります。")
        end
      end

      # 欄の値がどの科目にも無いと、算入された単位はグループを決められず、この規則は必ず要確認になる。
      def field_without_values(node, field)
        courses = input.courses_in(node.rule['category'])
        return if courses.empty? || courses.any? { |course| text?(course[field].to_s) }

        findings.warning(:rule, node.target,
                         "group_by が指す欄「#{field}」に値のある科目が、区分「#{node.rule['category']}」にありません。この規則は必ず要確認になります。")
      end

      def children(node)
        field = Input::NESTING.fetch(node.rule['type']).first
        return unless node.rule[field].empty?

        findings.warning(:rule, node.target, "#{node.rule['type']} の #{field} が空です。この規則は判定できず、必ず要確認になります。")
      end

      # cap の上限・exclude の理由と接頭辞は、読み込み時の構築がそのまま検める。同じ文面を画面に出す。
      def adjustment(node)
        Rules.adjustment(node.rule)
      rescue ArgumentError => e
        findings.blocking(:rule, node.target, "#{e.message}。算入してはいけない単位を数えるので、公開すると便覧を読み込めません。")
      end
    end
  end
end

