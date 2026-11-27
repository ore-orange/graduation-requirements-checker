# frozen_string_literal: true

class RequirementsReader
  # Gemini の答えが下書きに入れられる形かを確かめ、入れる形に整える。
  # スキーマは欄の型までしか縛れないので、型ごとに必ず要る欄と、識別子の書き方はここで見る。
  # 区分や規則がほかのページにあるかもしれないので、ページをまたぐ参照(未知の区分など)はここでは咎めない。
  module Answer
    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
    # 型ごとに、空にできない欄。
    REQUIRED = {
      'credit_sum' => %w[categories required_credits],
      'grouped_max' => %w[category group_by required_credits missing_group_note],
      'one_of_paths' => %w[paths],
      'all_required' => %w[expected_course_count required_credits required_categories],
      'any_of' => %w[options],
      'all_of' => %w[conditions],
      'cap' => %w[category credits reason],
      'exclude' => %w[category reason]
    }.freeze

    module_function

    def problems(answer)
      return ['答えがJSONのオブジェクトではない'] unless answer.is_a?(Hash)

      key_problems(answer) + Array(answer['rules']).flat_map { |rule| rule_problems(rule, rule['id'].to_s) } +
        display_problems(answer['display'])
    end

    # null の欄を落とす(書かれていない欄と同じに扱う)。画面の行は欄をそろえたまま残す。
    def tidy(answer)
      {
        'categories' => Array(answer['categories']),
        'roles' => Array(answer['roles']),
        'rules' => Array(answer['rules']).map { |rule| compact(rule) },
        'display' => answer['display']
      }
    end

    def compact(value)
      case value
      when Hash then value.compact.transform_values { |child| compact(child) }
      when Array then value.map { |child| compact(child) }
      else value
      end
    end

    def key_problems(answer)
      keys = Array(answer['categories']).pluck('key') + Array(answer['roles']).pluck('key') +
             Array(answer['rules']).pluck('id')
      keys.reject { |key| key.to_s.match?(KEY_FORMAT) }.map { |key| "識別子 #{key.inspect} の書き方" }
    end

    def rule_problems(rule, name)
      missing = REQUIRED.fetch(rule['type'], []).select { |field| blank?(rule[field]) }
      own = missing.map { |field| "#{name} の #{field} が無い" }
      nested = Array(rule['options']) + Array(rule['conditions'])
      own + nested.flat_map { |child| rule_problems(child, "#{name} の中の #{child['type']}") }
    end

    def display_problems(display)
      return ['display が無い'] unless display.is_a?(Hash)

      ids = Array(display['groups']).flat_map { |group| [group['id'], *Array(group['rows']).pluck('id')] }
      ids.reject { |id| id.to_s.match?(KEY_FORMAT) }.map { |id| "画面の章・行 #{id.inspect} の書き方" }
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end

