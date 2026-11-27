# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # conditions をすべて満たす。any_of の選択肢としてだけ置く(単独のチェックにはならない)。
    class AllOf < Base
      def conditions
        @conditions ||= definition.fetch('conditions').map { |condition| Rules.condition(condition, ALL_OF_CONDITIONS) }
      end

      def grouped_rules = conditions.flat_map(&:grouped_rules)

      def outcome(catalogue, ledger)
        results = conditions.map { |condition| condition.outcome(catalogue, ledger) }
        Outcome.new(satisfied: results.all?(&:satisfied), review: results.any?(&:review), counted: nil)
      end

      def counted_values(catalogue, ledger)
        conditions.map { |condition| condition.counted_values(catalogue, ledger) }.reduce({}, :merge)
      end
    end
  end
end

