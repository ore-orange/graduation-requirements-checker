# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 区分の算入単位に上限を設ける調整。判定は作らず、条件を評価する前に台帳の算入を打ち切る。
    # 上限は区分ごとに1つで、区分をまたぐ上限は持たない。
    class Cap
      attr_reader :definition

      def initialize(definition)
        @definition = definition
      end

      def id
        definition.fetch('id')
      end

      def apply(catalogue, ledger)
        category = definition.fetch('category')
        remaining = limit
        # 入力順ではなく正規キー順に上限を配分し、説明を安定させる。
        ledger.items.sort_by { |key, _| key }.each do |_, item|
          next unless item.course['category'] == category && item.counted.positive?

          allowed = [remaining, item.counted].min
          item.reason = reason(catalogue, allowed) if allowed < item.counted
          item.counted = allowed
          remaining -= allowed
        end
      end

      private

      def limit
        BigDecimal(definition.fetch('credits').to_s)
      end

      # 区分名は便覧の categories から読む（なければ区分のキー）。
      def reason(catalogue, allowed)
        name = catalogue.label_for(definition.fetch('category'))
        "#{name}は卒業算入上限#{format_credits(limit)}単位（この科目は#{allowed.to_s('F')}単位を算入）"
      end

      # 整数の上限は「2」、小数は「1.5」と書く（BigDecimal の to_s('F') は「2.0」になる）。
      def format_credits(value)
        value.frac.zero? ? value.to_i.to_s : value.to_s('F')
      end
    end
  end
end

