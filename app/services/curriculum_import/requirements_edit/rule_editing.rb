# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 規則の修正。欄ごとの値と、規則全体の JSON(経路・入れ子など、1つの欄で直せないもの)、規則を足す入口。
    module RuleEditing
      private

      def edit_rules
        entries = entries(@params[:rules], 'rules') or return
        rules = list_of(@document, 'rules') or return

        entries.each do |entry|
          index = rules.index { |rule| rule['id'] == entry[:id] }
          next error("規則「#{entry[:id]}」は下書きにありません。", 'rule', entry[:id]) unless index
          next discard(rules.delete_at(index), 'rule') if destroy?(entry)

          rules[index] = edit_rule(rules[index], entry)
        end
      end

      # JSON の欄が元と違えば、規則を JSON で置き換える。同じなら、欄ごとの値を当てる。id は変えられない。
      def edit_rule(rule, entry)
        name = "規則「#{rule['id']}」"
        json = entry[:json].to_s.strip
        replaced = parse_rule(json, rule, name) if json.present?
        if replaced && replaced != rule.except(DraftMerge::CONFIRMED)
          mark(replaced, true)
          return replaced.merge('id' => rule['id'])
        end

        rule.deep_dup.tap do |copy|
          mark(copy, assign(copy, entry, self.class.rule_fields(copy), 'rule', rule['id']).any?)
        end
      end

      def parse_rule(json, rule, name)
        parsed = JSON.parse(json)
        return error("#{name}の JSON は、規則1つ分のオブジェクトにしてください。", 'rule', rule['id']) unless parsed.is_a?(Hash)
        return parsed if parsed['id'].nil? || parsed['id'] == rule['id']

        error("#{name}の id は変えられません。", 'rule', rule['id'])
      rescue JSON::ParserError
        error("#{name}の JSON を読めません。括弧・引用符・カンマを確かめてください。", 'rule', rule['id'])
      end

      # AI が読み落とした要件を、人が足す。足した規則は、読み直しで消えないよう印を付ける。
      def add_new_rule
        json = @params[:new_rule_json].to_s.strip
        return if json.blank?

        rule = JSON.parse(json)
        return error('足す規則の JSON は、規則1つ分のオブジェクトにしてください。', 'new_rule', 'new') unless rule.is_a?(Hash)

        problem = new_rule_problem(rule)
        return error(problem, 'new_rule', 'new') if problem

        clear_removed('rule', rule['id'])
        list_of(@document, 'rules')&.push(rule.merge(DraftMerge::CONFIRMED => true))
        @edited += 1
        @notes << "規則「#{rule['id']}」を足しました。"
      rescue JSON::ParserError
        error('足す規則の JSON を読めません。括弧・引用符・カンマを確かめてください。', 'new_rule', 'new')
      end

      def new_rule_problem(rule)
        return '足す規則には id(文字列)が要ります。' unless rule['id'].is_a?(String) && rule['id'].strip.present?
        unless Validation::Input::TOP_LEVEL.include?(rule['type'])
          return "足す規則の type は次のどれかにしてください: #{Validation::Input::TOP_LEVEL.join('・')}。"
        end
        return unless Array(@document['rules']).grep(Hash).any? { |other| other['id'] == rule['id'] }

        "規則の id「#{rule['id']}」はすでにあります。"
      end
    end
  end
end

