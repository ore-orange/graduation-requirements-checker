# frozen_string_literal: true

class GraduationAssessment
  module Rules
    class Base
      attr_reader :definition

      def initialize(definition)
        @definition = definition
      end

      def id
        definition.fetch('id')
      end

      def label
        definition.fetch('label')
      end

      def evaluate(_catalogue, _ledger)
        raise NotImplementedError, "#{self.class}#evaluate"
      end

      # 経路の混在など、他の規則と判定を突き合わせる型だけが上書きする。
      def reconcile(_catalogue, _ledger); end

      def check(catalogue, ledger)
        outcome = evaluate(catalogue, ledger)
        status = Rules.status(outcome.satisfied, outcome.review)
        Check.new(id: id, label: label, status: status, counted_credits: outcome.counted,
                  required_credits: definition['required_credits'], missing_courses: outcome.missing,
                  source: definition['source_page'], detail: detail(catalogue, outcome, status))
      end

      private

      def detail(_catalogue, outcome, status)
        required = definition['required_credits']
        text = "#{definition['detail']} 確認済み算入#{outcome.counted.to_s('F')}／必要#{required}単位。"
        deficit = [BigDecimal(required.to_s) - outcome.counted, Catalogue::ZERO].max
        text += "不足#{deficit.to_s('F')}単位。" if status == :unmet
        text += '未確認事項により不足の確定はできません。' if status == :needs_review
        text.strip
      end
    end
  end
end

