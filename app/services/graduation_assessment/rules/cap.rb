# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 区分の算入単位を credits で打ち切る調整。科目のキー順に配分し(説明を毎回同じにするため)、
    # 打ち切った科目には reason を残す。
    class Cap
      attr_reader :category, :credits, :reason

      def initialize(definition)
        @category = definition.fetch('category')
        @credits = Ledger.decimal(definition.fetch('credits'))
        @reason = definition.fetch('reason')
        raise ArgumentError, "cap の credits は0以上の数にしてください: #{definition['credits'].inspect}" if @credits.nil?
      end

      def apply(ledger)
        ledger.cap(category, credits) { |allowed| "#{reason}（この科目は#{allowed.to_s('F')}単位を算入）" }
      end
    end
  end
end

