# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # options のどれか1つを満たせばよい。
    # 例: 外国語は「英語12単位」または「英語8単位かつ同じ一外国語4単位」。
    #
    # 画面に出す単位は counted_from に書いた選択肢の値。detail には、入れ子の条件の値を {{id}} で差し込める。
    class AnyOf < Base
      def options
        @options ||= definition.fetch('options').map { |option| Rules.condition(option, ANY_OF_OPTIONS) }
      end

      def grouped_rules = options.flat_map(&:grouped_rules)

      def outcome(catalogue, ledger)
        results = options.map { |option| option.outcome(catalogue, ledger) }
        Outcome.new(satisfied: results.any?(&:satisfied), review: results.any?(&:review), counted: nil)
      end

      def counted_values(catalogue, ledger)
        options.map { |option| option.counted_values(catalogue, ledger) }.reduce({}, :merge)
      end

      def check(catalogue, ledger)
        result = outcome(catalogue, ledger)
        values = counted_values(catalogue, ledger)
        build_check(status: Rules.status(result.satisfied, result.review), counted: values[definition['counted_from']],
                    required: nil, missing: [], detail: fill(definition['detail'].to_s, values))
      end

      private

      # 知らない id は、そのまま残す(便覧の書き間違いを、空文字で隠さない)。
      def fill(template, values)
        template.gsub(/\{\{(\w+)\}\}/) do |token|
          name = token.delete_prefix('{{').delete_suffix('}}')
          values.key?(name) ? values[name].to_s('F') : token
        end
      end
    end
  end
end

