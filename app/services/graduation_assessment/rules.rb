# frozen_string_literal: true

class GraduationAssessment
  # 卒業要件の規則を、curriculum JSON の定義（String キーの Hash）から評価する。
  # 型は閉じた語彙で、`type` から対応するクラスを引く。
  module Rules
    # satisfied/review は真偽、counted は BigDecimal（単位を数えない型では nil）、
    # missing は未修得の科目名の配列。
    Outcome = Struct.new(:satisfied, :review, :counted, :missing, keyword_init: true)

    TYPES = {
      'credit_sum' => 'CreditSum',
      'all_required' => 'AllRequired',
      'one_of_paths' => 'OneOfPaths',
      'grouped_max' => 'GroupedMax',
      'any_of' => 'AnyOf',
      'all_of' => 'AllOf'
    }.freeze

    # 単独の規則として置ける型。all_of は any_of の選択肢としてだけ現れるので含めない。
    TOP_LEVEL = (TYPES.keys - %w[all_of]).freeze

    # 入れ子で許す型。any_of → all_of の2段までで、それより深いものや他の型は Unknown にする。
    ANY_OF_OPTIONS = %w[credit_sum grouped_max all_of].freeze
    ALL_OF_CONDITIONS = %w[credit_sum grouped_max].freeze

    def self.status(satisfied, review)
      return :satisfied if satisfied

      review ? :needs_review : :unmet
    end

    # 許可していない type は例外にせず Unknown（要確認）にする。解釈できない規則を充足と答えないための弁。
    def self.condition(definition, allowed = TOP_LEVEL)
      type = definition['type'] if definition.is_a?(Hash)
      return Unknown.new(definition.is_a?(Hash) ? definition : {}) unless allowed.include?(type)

      const_get(TYPES.fetch(type)).new(definition)
    end
  end
end

