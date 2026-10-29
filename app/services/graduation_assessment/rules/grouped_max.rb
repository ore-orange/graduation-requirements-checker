# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 区分の算入単位を科目番号でグループに分け、最大のグループが必要単位に届くかを見る。
    # グループを合算しない（同一の提供コース、同一の外国語など）。
    class GroupedMax < Base
      def evaluate(_catalogue, ledger)
        category = definition.fetch('category')
        largest = ledger.grouped_credits_by_number(category, definition.fetch('group_by')).values.max
        counted = largest || Catalogue::ZERO
        Outcome.new(satisfied: counted >= definition.fetch('required_credits'),
                    review: ledger.unreadable_number?(category) || ledger.uncertain?([category]),
                    counted: counted, missing: [])
      end
    end
  end
end

