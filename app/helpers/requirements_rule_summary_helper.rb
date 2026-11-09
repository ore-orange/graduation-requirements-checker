# frozen_string_literal: true

# 規則の中身を、確認画面が一覧できる文の並びにする部分。値の書式・欄の名前は RequirementsReviewHelper が持つ。
module RequirementsRuleSummaryHelper
  SUMMARY_FIELDS = %w[categories required_categories category required_credits expected_course_count group_by credits
                      number_prefix reason review_note].freeze

  # 規則の中身を、画面が一覧できる文の並びにする。判定の数字を決める値は、すべてここに出す
  # (上限・接頭辞・経路・入れ子の選択肢の必要単位)。読み違えると、数えてはいけない単位が数えられる値が、
  # 開かないと見えない JSON の中にあってはいけない。入れ子は、親の下に字下げして出す。
  def rule_summary(rule, review, depth = 0)
    indent = '　' * depth
    lines = [fields_line(rule, review)].compact.map { |line| "#{indent}#{line}" }
    lines.concat(path_lines(rule, review).map { |line| "#{indent}#{line}" })
    nested_rules(rule).each do |name, index, child|
      lines << "#{indent}#{name}#{index}: #{rule_type_name(child['type'])}"
      lines.concat(rule_summary(child, review, depth + 1))
    end
    lines
  end

  def fields_line(rule, review)
    parts = SUMMARY_FIELDS.filter_map do |field|
      if rule.key?(field)
        "#{RequirementsReviewHelper::FIELD_NAMES.fetch(field)}: #{summary_value(rule[field], field,
                                                                                review)}"
      end
    end
    parts << '科目番号の接頭辞: なし(区分の全体)' if rule['type'] == 'exclude' && !rule.key?('number_prefix')
    parts.join(' / ').presence
  end

  # 経路は、役割のキーに、その役割を持つ科目の名前を添える。科目が1つも無い役割は、そう言う。
  def path_lines(rule, review)
    return [] unless rule['paths'].is_a?(Array)

    rule['paths'].each_with_index.map do |path, index|
      roles = Array(path).map { |role| "#{role}(#{review.role_names(role).first(3).join('・').presence || '科目なし'})" }
      "経路#{index + 1}: #{roles.join(' ＋ ').presence || '(空)'}"
    end
  end

  def nested_rules(rule)
    { 'options' => '選択肢', 'conditions' => '条件' }.flat_map do |field, name|
      Array(rule[field]).grep(Hash).each_with_index.map { |child, index| [name, index + 1, child] }
    end
  end

  def summary_value(value, field, review)
    return review_credits(value) if value.is_a?(Numeric)
    return '(空)' if value.nil?

    names = Array(value).map { |key| category_field?(field) ? review.category_label(key) : key.to_s }
    names.join('・').presence || '(空)'
  end

  def category_field?(field) = %w[categories required_categories category].include?(field)
end

