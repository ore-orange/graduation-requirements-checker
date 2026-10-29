# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 選択肢のどれか1つを満たせばよい。どの選択肢も評価し、未確定や注記を取りこぼさない。
    class AnyOf < Base
      def initialize(definition)
        super
        @options = definition.fetch('options').map { |option| Rules.condition(option, ANY_OF_OPTIONS) }
      end

      # counted は表示用で、便覧の第一の経路である最初の選択肢の値を使う。
      def evaluate(catalogue, ledger)
        outcomes = @options.map { |option| option.evaluate(catalogue, ledger) }
        Outcome.new(satisfied: outcomes.any?(&:satisfied), review: outcomes.any?(&:review),
                    counted: outcomes.first&.counted, missing: [])
      end

      private

      def detail(_catalogue, _outcome, status)
        text = definition['detail'].to_s
        text += ' 未確認事項により不足の確定はできません。' if status == :needs_review
        text.strip
      end
    end
  end
end

