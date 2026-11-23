# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 指定した区分の算入単位の合計が、必要単位に届くか。
    class CreditSum < Base
      def outcome(_catalogue, ledger)
        categories = definition.fetch('categories')
        counted = ledger.sum(categories)
        Outcome.new(satisfied: counted >= definition.fetch('required_credits'),
                    review: ledger.uncertain?(categories), counted: counted)
      end

      def check(catalogue, ledger) = credit_check(catalogue, ledger)

      def counted_values(catalogue, ledger)
        id ? { id => outcome(catalogue, ledger).counted } : {}
      end
    end
  end
end

