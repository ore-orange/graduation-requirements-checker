# frozen_string_literal: true

class CurriculumReader
  # 読み取りの答えを、スキーマの検査のあとで確かめ、使う形に整える。
  # 検査は窓口が自分で行う。プロバイダがスキーマを守らせたかどうかには頼らない。
  module Answer
    # 値が null なのが意味を持つ欄。表示の行の「必要単位なし(内数)」と、その理由。ほかの null は欄が無いのと同じに扱う。
    KEEP_NULL = %w[required_credits required_label].freeze

    class << self
      # スキーマの検査に加えて、型ごとに要る欄と、表示の行の整合を見る。問題の一覧(空なら合格)。
      def requirements_problems(answer)
        problems = Shape.problems(answer, Schemas.requirements)
        return problems if problems.any?

        answer['rules'].each_with_index { |rule, index| problems.concat(rule_problems(rule, "$.rules[#{index}]")) }
        problems.concat(display_problems(answer['display']))
      end

      # null の欄を落とす(規則の読み込みは、欄が無いことと null を別に扱う)。表示の行の必要単位とラベルだけは null を残す。
      def tidy_requirements(answer)
        { 'categories' => answer['categories'],
          'rules' => compact(answer['rules'], keep_null: []),
          'display' => compact(answer['display'], keep_null: KEEP_NULL) }
      end

      private

      def rule_problems(rule, path)
        missing = Schemas::RULE_REQUIRED.fetch(rule['type']).select { |field| rule[field].nil? }
        problems = missing.map { |field| "#{path}(#{rule['type']}) に #{field} がありません" }
        %w[options conditions].each do |field|
          Array(rule[field]).each_with_index do |child, index|
            problems.concat(rule_problems(child, "#{path}.#{field}[#{index}]"))
          end
        end
        problems
      end

      # 必要単位を持たない行は、理由のラベルが要る。ラベルが無いと、満たしていない要件が画面から消える。
      def display_problems(display)
        display['groups'].flat_map.with_index do |group, group_index|
          group['rows'].each_with_index.filter_map do |row, row_index|
            next unless row['required_credits'].nil? && row['required_label'].to_s.strip.empty?

            "$.display.groups[#{group_index}].rows[#{row_index}] は必要単位が null なので required_label が要ります"
          end
        end
      end

      def compact(value, keep_null:)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if child.nil? && keep_null.exclude?(key)

            result[key] = compact(child, keep_null: keep_null)
          end
        when Array then value.map { |child| compact(child, keep_null: keep_null) }
        else value
        end
      end
    end
  end
end

