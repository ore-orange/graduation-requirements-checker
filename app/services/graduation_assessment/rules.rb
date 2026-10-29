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
      'one_of_paths' => 'OneOfPaths'
    }.freeze

    def self.status(satisfied, review)
      return :satisfied if satisfied

      review ? :needs_review : :unmet
    end

    def self.condition(definition)
      type = definition['type']
      # 未知の type はここで Rules::Unknown を返すようにする（Task 4）。
      raise ArgumentError, "未対応の規則の型: #{type.inspect}" unless TYPES.key?(type)

      const_get(TYPES.fetch(type)).new(definition)
    end
  end
end

