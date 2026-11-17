# frozen_string_literal: true

module CurriculumImport
  # 規則の型の和名。画面(RequirementsReviewHelper)と、突き合わせの指摘(Validation)が同じ名前で呼ぶための表。
  module RuleTypeNames
    NAMES = { 'credit_sum' => '区分の合計単位', 'all_required' => '必修をすべて修得', 'one_of_paths' => '指定科目の系列',
              'grouped_max' => '同じ提供元・言語から', 'any_of' => 'どれか1つを満たす', 'all_of' => 'すべてを満たす',
              'cap' => '算入の上限', 'exclude' => '算入しない' }.freeze

    # 知らない型は nil(呼び手が、型なしの言い方を決める)。
    def self.for(type) = NAMES[type]
  end
end

