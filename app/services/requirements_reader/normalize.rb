# frozen_string_literal: true

class RequirementsReader
  # Gemini の答えの、意味の同じ書き方の揺れを、決めた形にそろえる(Answer が確かめる前に行う)。
  # 例: 区分が1つだけの credit_sum を categories の配列ではなく category の文字列で返す、
  #     exclude に区分を categories の配列でまとめて返す、exclude の理由(reason)を書かない。
  module Normalize
    # 区分を1つだけ持つ型(category)。credit_sum は区分の配列(categories)を持つ。
    SINGLE_CATEGORY = %w[grouped_max cap exclude].freeze

    module_function

    def blank?(value) = Answer.blank?(value)

    # 意味の同じ書き方の揺れを、決めた形にそろえる。入れ子の条件もそろえる。
    def rule(rule)
      return rule unless rule.is_a?(Hash)

      rule = normalize_children(rule)
      rule = normalize_categories(rule)
      return rule unless rule['type'] == 'exclude' && blank?(rule['reason'])

      # 理由が無ければ、規則の見出しや注記を理由にする(便覧の言い方なので、作った文ではない)。
      rule.merge('reason' => rule['detail'].presence || rule['label'])
    end

    def normalize_children(rule)
      %w[options conditions].reduce(rule) do |current, field|
        children = current[field]
        children.is_a?(Array) ? current.merge(field => children.map { |child| rule(child) }) : current
      end
    end

    def normalize_categories(rule)
      if rule['type'] == 'credit_sum' && blank?(rule['categories']) && rule['category'].present?
        return rule.except('category').merge('categories' => [rule['category']])
      end
      return rule unless SINGLE_CATEGORY.include?(rule['type']) && blank?(rule['category'])

      categories = Array(rule['categories'])
      categories.one? ? rule.except('categories').merge('category' => categories.first) : rule
    end

    # 複数の区分をまとめて「数えない」とした exclude は、区分ごとの exclude に分ける。
    def expand(rule)
      return [rule] unless rule.is_a?(Hash) && rule['type'] == 'exclude' && blank?(rule['category'])

      categories = Array(rule['categories'])
      return [rule] if categories.empty?

      categories.each_with_index.map do |category, index|
        rule.except('categories').merge('id' => "#{rule['id']}_#{index + 1}", 'category' => category)
      end
    end
  end
end

