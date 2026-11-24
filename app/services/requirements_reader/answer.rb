# frozen_string_literal: true

class RequirementsReader
  # Gemini の答えを、下書きに入れる形に整える。
  #
  # 答えの欄の書き方は、同じ依頼でも回ごとに揺れる(区分を category と書いたり categories と書いたり)。
  # 意味の同じ揺れは決めた形にそろえ(normalize)、それでも使えない規則・区分・章立ての行だけを外して警告にする。
  # 1つの規則が壊れているだけで、ページ全体を捨てない(取り込んだあとに人が確認して直すため)。
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

    # [整えた答え, 警告の配列]。答えがオブジェクトでなければ、読み取りの失敗にする。
    def call(answer)
      raise RequirementsReader::Error, RequirementsReader::MESSAGES[:answer] unless answer.is_a?(Hash)

      warnings = []
      rules = Array(answer['rules']).flat_map { |rule| Normalize.expand(Normalize.rule(rule)) }
      tidy = {
        'categories' => keyed(answer['categories'], '科目区分', warnings),
        'roles' => keyed(answer['roles'], '指定科目', warnings),
        'rules' => usable_rules(rules, warnings).map { |rule| compact(rule) },
        'display' => display(answer['display'], warnings)
      }
      [tidy, warnings]
    end

    def usable_rules(rules, warnings)
      rules.select do |rule|
        problems = rule_problems(rule, rule['id'].to_s)
        problems.unshift("識別子 #{rule['id'].inspect} の書き方") unless rule['id'].to_s.match?(KEY_FORMAT)
        warnings << rule_warning(rule, problems) if problems.any?
        problems.empty?
      end
    end

    # 取り込まなかった規則の知らせ。事務の方が読むので、欄の名前は出さず、何が読めなかったかを言う。
    # 詳しい理由は開発者向けにログへ残す。
    def rule_warning(rule, problems)
      Rails.logger.info("要件表の規則を取り込みませんでした: #{rule['id']} #{problems.join('、')}")
      title = rule['label'].presence || '名前の無い条件'
      "「#{title}」は、#{missing_part(problems.join)}が読み取れなかったため、取り込んでいません。PDFで確認してください。"
    end

    # 欠けていた欄から、事務の方に伝える「読み取れなかったもの」を選ぶ。
    def missing_part(problems)
      return 'どの科目区分を数えるのか' if problems.include?('categor')
      return '必要な単位数' if problems.match?(/credits|expected_course_count/)

      '条件の中身'
    end

    def rule_problems(rule, name)
      return ["#{name} がオブジェクトではない"] unless rule.is_a?(Hash)

      missing = REQUIRED.fetch(rule['type'], []).select { |field| blank?(rule[field]) }
      own = missing.map { |field| "#{name} の #{field} が無い" }
      nested = Array(rule['options']) + Array(rule['conditions'])
      own + nested.flat_map { |child| rule_problems(child, "#{name} の中の #{child.is_a?(Hash) ? child['type'] : '要素'}") }
    end

    # 区分・役割のうち、識別子の書き方が違うものを外す。
    def keyed(entries, name, warnings)
      Array(entries).select do |entry|
        usable = entry.is_a?(Hash) && entry['key'].to_s.match?(KEY_FORMAT)
        warnings << "読み取った#{name}の一部(「#{entry_name(entry, 'label')}」)を取り込めませんでした。" unless usable
        usable
      end
    end

    # 章立てのうち、識別子の書き方が違う章・行を外す。章立てが無ければ空にする。
    def display(display, warnings)
      unless display.is_a?(Hash)
        warnings << '要件表の見出しと行の組み立てを読み取れませんでした。'
        return { 'total_credits' => nil, 'groups' => [] }
      end

      groups = Array(display['groups']).select { |group| usable_id?(group, '見出し', warnings) }
      display.merge('groups' => groups.map { |group| group.merge('rows' => usable_rows(group, warnings)) })
    end

    def usable_rows(group, warnings)
      Array(group['rows']).select { |row| usable_id?(row, '行', warnings) }
    end

    def usable_id?(entry, name, warnings)
      usable = entry.is_a?(Hash) && entry['id'].to_s.match?(KEY_FORMAT)
      unless usable
        warnings << "要件表の#{name}の一部(「#{entry_name(entry, name == '見出し' ? 'title' : 'name')}」)を取り込めませんでした。"
      end
      usable
    end

    def entry_name(entry, field)
      entry.is_a?(Hash) ? entry[field].to_s : entry.to_s[0, 20]
    end

    # null の欄を落とす(書かれていない欄と同じに扱う)。
    def compact(value)
      case value
      when Hash then value.compact.transform_values { |child| compact(child) }
      when Array then value.map { |child| compact(child) }
      else value
      end
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end

