# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 入れ子で送られてくる欄(one_of_paths の経路、any_of の選択肢、all_of の条件)を、文書に入る形にする。
    # 1つの欄で直せる値は Coercion が、繰り返しの行で送られる値はここが読む。
    module NestedCoercion
      # 入れ子の条件に置ける型。any_of の選択肢には all_of を置けるが、all_of の条件には置けない
      # (判定が読む入れ子は2階層まで。GraduationAssessment::Rules の決まりと同じ表)。
      NESTED_TYPES = { options: GraduationAssessment::Rules::ANY_OF_OPTIONS,
                       conditions: GraduationAssessment::Rules::ALL_OF_CONDITIONS }.freeze

      private

      def nested_coerce(value, kind, name)
        case kind
        when :paths then paths(value, name)
        when :options, :conditions then conditions(value, kind, name)
        end
      end

      # 経路。画面は経路ごとに1行(rules[N][paths][M][roles][])で送る。1つの経路は、そろって要る役割の並び。
      # 役割を1つも選ばなかった経路は捨てる(空の経路は「何も修得しなくてよい経路」になり、規則を骨抜きにする)。
      def paths(value, name)
        rows = nested_rows(value, name)
        return :invalid if rows == :invalid

        rows.filter_map { |row| list(row[:roles] || row['roles'], name).presence }
      end

      # any_of の選択肢・all_of の条件。型ごとに、その型が持てる欄だけを組み立て直す。
      # 読めない型・置けない型の条件は捨てて、問題を積む(黙って落とすと、要件が1つ消えたまま保存される)。
      def conditions(value, kind, name)
        rows = nested_rows(value, name)
        return :invalid if rows == :invalid

        built = rows.map { |row| condition(row, kind, name) }
        return :invalid if built.include?(:invalid)

        # 種類のほかに何も入っていない条件は捨てる(足したまま書かなかった行。
        # 「区分なしで0単位」の条件は、何も数えないまま満たされたことになってしまう)。
        # all_of だけは残す。中の条件は、画面に出てから1つずつ足すので、足した直後は必ず空になる。
        # 条件の無い all_of は、突き合わせ(RuleShape)が指摘する。
        built.reject { |condition| condition['type'] != 'all_of' && empty_condition?(condition) }
      end

      def empty_condition?(condition)
        condition.except('type').values.all? { |value| value.nil? || value == [] }
      end

      def condition(row, kind, name)
        type = row[:type].presence || row['type'].presence
        unless NESTED_TYPES.fetch(kind).include?(type)
          return invalid("#{name}に置ける条件の種類は #{NESTED_TYPES.fetch(kind).join('・')} です(入れた値: #{type.to_s.first(20)})。")
        end

        fields = condition_fields(row, type, name)
        return :invalid if fields.value?(:invalid)

        { 'type' => type }.merge(fields.compact)
      end

      # 条件が持てる欄は、規則そのものと同じ表(RequirementsEdit.condition_fields)から決める。画面もこの表で欄を出すので、
      # 送られてくる欄と、組み立て直す欄が必ず一致する(表に無い欄は、画面に出ず、保存で消える)。
      # all_of の中の条件だけは、もう1段だけ :conditions として読む(その中に all_of は置けない)。
      def condition_fields(row, type, name)
        fields = RequirementsEdit.condition_fields(type)
        fields = fields.merge('conditions' => :conditions) if type == 'all_of'
        fields.to_h do |field, kind|
          [field, coerce(row[field] || row[field.to_sym], kind, "#{name}の#{FIELD_LABELS.fetch(field, field)}")]
        end
      end

      # 画面は入れ子の行を { '<一意な印>' => {...} } で送る(添字は振り直さないので、並びは送られた順)。
      def nested_rows(value, name)
        case value
        when Array then value.grep(Hash)
        when Hash then value.values.grep(Hash)
        when nil then []
        else invalid("#{name}の形が違います。")
        end
      end
    end
  end
end

