# frozen_string_literal: true

class GraduationAssessment
  # 便覧の rules(String キーの Hash)を、判定の部品にする。型は閉じた一覧で、type から部品を引く。
  #
  # 条件(condition)は1つのチェックを返す。調整(cap・exclude)はチェックを作らず、条件を評価する前に算入を変える。
  module Rules
    # satisfied・review は真偽、counted は BigDecimal(単位を数えない型では nil)。入れ子の条件どうしで受け渡す。
    Outcome = Data.define(:satisfied, :review, :counted)

    CONDITIONS = {
      'credit_sum' => 'CreditSum',
      'grouped_max' => 'GroupedMax',
      'one_of_paths' => 'OneOfPaths',
      'all_required' => 'AllRequired',
      'any_of' => 'AnyOf',
      'all_of' => 'AllOf'
    }.freeze
    ADJUSTMENTS = { 'cap' => 'Cap', 'exclude' => 'Exclude' }.freeze

    # 単独で置ける型。all_of は any_of の選択肢としてだけ置く。
    TOP_LEVEL = (CONDITIONS.keys - %w[all_of]).freeze
    # 入れ子は any_of → all_of の2段まで。
    ANY_OF_OPTIONS = %w[credit_sum grouped_max all_of].freeze
    ALL_OF_CONDITIONS = %w[credit_sum grouped_max].freeze

    module_function

    def status(satisfied, review)
      return :satisfied if satisfied

      review ? :needs_review : :unmet
    end

    def adjustment?(definition)
      definition.is_a?(Hash) && ADJUSTMENTS.key?(definition['type'])
    end

    # 置けない型・知らない型は例外にせず Unknown(必ず要確認)にする。解釈できない規則を充足と答えないため。
    def condition(definition, allowed = TOP_LEVEL)
      definition = {} unless definition.is_a?(Hash)
      return Unknown.new(definition) unless allowed.include?(definition['type'])

      const_get(CONDITIONS.fetch(definition['type'])).new(definition)
    end

    # 調整を黙って落とすと、算入してはいけない単位を数えてしまうので、壊れた調整は例外にする。
    def adjustment(definition)
      const_get(ADJUSTMENTS.fetch(definition['type'])).new(definition)
    end
  end
end

