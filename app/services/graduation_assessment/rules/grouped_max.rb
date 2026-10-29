# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 区分の算入単位を group_by（科目番号の接頭辞、または field:<欄名>）でグループに分け、
    # 最大のグループが必要単位に届くかを見る。グループを合算しない（同一の提供コース、同一の外国語など）。
    class GroupedMax < Base
      def evaluate(catalogue, ledger)
        category = definition.fetch('category')
        group_by = definition.fetch('group_by')
        largest = ledger.grouped_credits_by(category, group_by).values.max
        counted = largest || Catalogue::ZERO
        ungrouped = note_ungrouped(catalogue, ledger, ledger.ungrouped_courses(category, group_by))
        Outcome.new(satisfied: counted >= definition.fetch('required_credits'),
                    review: ungrouped.any? || ledger.uncertain?([category]),
                    counted: counted, missing: [])
      end

      private

      # グループを決められない科目が何で、どう扱ったかを残す。check の時点で動くので、Ledger#note のように
      # 正規化が科目に残した reason を上書きしない（notes に足すだけ）。
      def note_ungrouped(catalogue, ledger, courses)
        courses.each { |course| ledger.notes << "#{course.fetch('name')}：#{ungrouped_reason(catalogue)}" }
      end

      # 学生に見せる欄の呼び名は便覧ごとに違うので定義に持たせる。無ければ欄の名前をそのまま使う。
      def group_label
        definition['group_label'].presence || definition.fetch('group_by').delete_prefix(Ledger::FIELD_GROUP)
      end

      def ungrouped_reason(catalogue)
        group_by = definition.fetch('group_by')
        name = catalogue.label_for(definition.fetch('category'))
        if group_by.to_s.start_with?(Ledger::FIELD_GROUP)
          "#{group_label}の欄が未確認（#{name}のグループ別の集計には未算入）"
        else
          "科目番号を読み取れず、グループが未確認（#{name}のグループ別の集計には未算入）"
        end
      end
    end
  end
end

