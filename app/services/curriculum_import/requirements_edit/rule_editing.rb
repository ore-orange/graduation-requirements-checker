# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 規則の修正。欄ごとの値(経路・入れ子の条件も含めて、すべて欄から)と、規則を足す入口。
    module RuleEditing
      # 「決まりを足す」の組が書かれているかを見る欄。どれかが埋まっていれば、足そうとしていると見なす。
      # id は無い。人は規則の id を打たず、アプリが裏で振る(設計書 項目5。RuleLinking)。
      NEW_RULE_START = %i[type label].freeze

      private

      def edit_rules
        entries = entries(@params[:rules], 'rules') or return
        rules = list_of(@document, 'rules') or return

        entries.each do |entry|
          index = rules.index { |rule| rule['id'] == entry[:id] }
          next error("規則「#{entry[:id]}」は下書きにありません。", 'rule', entry[:id]) unless index
          next discard(rules.delete_at(index), 'rule') if destroy?(entry)

          rules[index] = edit_rule(rules[index], entry)
          attach_rule(rules[index], entry)
        end
      end

      # 「結びつける先」が選ばれていたら、その章・枠・行に結びつける(設計書 項目5)。
      # 結びつけても、決まりそのものには印を付けない(値は AI の読みのままで、変えたのは結びつけだけ)。
      def attach_rule(rule, entry)
        return unless entry.key?(:link)

        link = in_context('rule', rule['id']) { parse_link(entry[:link]) }
        return unless link

        problem = link_rule(link, rule['id'])
        return error(problem, 'rule', rule['id']) if problem

        @notes << "規則「#{rule['id']}」を結びつけました。"
      end

      # 欄ごとの値を当てる。id と型は変えられない(型を変えると持てる欄が変わり、別の規則になる)。
      def edit_rule(rule, entry)
        rule.deep_dup.tap do |copy|
          mark(copy, assign(copy, entry, self.class.rule_fields(copy), 'rule', rule['id']).any?)
        end
      end

      # AI が読み落とした要件を、人が足す。型を選び、その型が持つ欄だけを、直すときと同じ読み方で組む。
      # 足した規則は、読み直しで消えないよう印を付ける。画面は空の組を毎回送るので、型も id も空なら何もしない。
      def add_new_rule
        entry = @params[:new_rule]
        return unless entry.is_a?(Hash)
        return if NEW_RULE_START.none? { |field| entry[field].to_s.strip.present? }

        in_context('new_rule', 'new') { build_and_append_new_rule(entry) }
      end

      def build_and_append_new_rule(entry)
        type = entry[:type].to_s.strip
        return error(new_rule_type_message) unless Validation::Input::TOP_LEVEL.include?(type)

        link = parse_link(entry[:link])
        rule = build_new_rule(type, entry).merge('id' => new_rule_id(link))
        return if @problems.any? { |item| item.kind == 'new_rule' }

        append_new_rule(rule)
        problem = link && link_rule(link, rule['id'])
        error(problem) if problem
      end

      # 型ごとの欄は、既存の規則を直すときと同じ表(rule_fields)から決める。
      # 画面もこの表で欄を出すので、出した欄と組み立てる欄が必ず一致する。
      #
      # 画面は型ごとの欄を全部出す(JavaScript が動かなくても書けるように)ので、同じ名前の欄が何組も届く。
      # 選んだ型の組(new_rule[fields][型])だけを見て、他の型の空欄に上書きされないようにする。
      # 型に関わらず1つしかない欄(名前など)は、組の外から見る。
      def build_new_rule(type, entry)
        skeleton = { 'type' => type }
        scoped = entry[:fields].is_a?(Hash) ? (entry[:fields][type] || {}) : {}
        built = self.class.rule_fields(skeleton).filter_map do |field, kind|
          given = scoped.key?(field) ? scoped[field] : entry[field]
          value = coerce(given, kind, "足す規則の#{FIELD_LABELS.fetch(field, field)}")
          [field, value] unless value == :invalid || value.nil?
        end
        skeleton.merge(built.to_h)
      end

      def append_new_rule(rule)
        list_of(@document, 'rules')&.push(rule.merge(DraftMerge::CONFIRMED => true))
        @edited += 1
        @notes << "規則「#{rule['id']}」を足しました。"
      end

      def new_rule_type_message
        "足す規則の種類は次のどれかにしてください: #{Validation::Input::TOP_LEVEL.join('・')}。"
      end
    end
  end
end

