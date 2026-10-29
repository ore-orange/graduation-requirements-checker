# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 並べた条件をすべて満たす。any_of の選択肢としてだけ使う（入れ子は2段まで）。
    class AllOf < Base
      def initialize(definition)
        super
        @conditions = definition.fetch('conditions').map do |condition|
          Rules.condition(condition, ALL_OF_CONDITIONS)
        end
      end

      # counted は表示用で、最初の条件の値を使う。
      def evaluate(catalogue, ledger)
        outcomes = @conditions.map { |condition| condition.evaluate(catalogue, ledger) }
        Outcome.new(satisfied: outcomes.all?(&:satisfied), review: outcomes.any?(&:review),
                    counted: outcomes.first&.counted, missing: [])
      end
    end
  end
end

