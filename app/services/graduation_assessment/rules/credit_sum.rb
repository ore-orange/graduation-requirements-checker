# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 指定した区分の算入単位の合計が、必要単位に届くかを見る。
    class CreditSum < Base
      def evaluate(_catalogue, ledger)
        categories = definition.fetch('categories')
        counted = ledger.sum(categories)
        Outcome.new(satisfied: counted >= definition.fetch('required_credits'),
                    review: ledger.uncertain?(categories), counted: counted, missing: [])
      end
    end
  end
end

