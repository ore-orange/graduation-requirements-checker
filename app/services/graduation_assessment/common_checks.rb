# frozen_string_literal: true

class GraduationAssessment
  class CommonChecks
    def initialize(catalogue, ledger)
      @catalogue = catalogue
      @ledger = ledger
      @credit = CreditCheck.new(ledger)
      @role = RoleCheck.new(catalogue, ledger)
    end

    def call
      general_checks + specified_checks + [foreign_language_check, common_total_check]
    end

    private

    def common_total_check
      @credit.call('common_total', '共通教育の合計', Catalogue::COMMON, 30)
    end

    def general_checks
      [
        @credit.call('health', '健康運動系', ['health'], 2),
        @credit.call('humanities', '人文系', ['humanities'], 2),
        @credit.call('social', '社会系', ['social'], 2),
        integrated_check,
        @credit.call('general_without_natural', '自然系を除く教養・総合領域', without_natural, 12),
        @credit.call('general_subtotal', '教養・総合領域の小計', without_natural + ['natural'], 14,
                     detail: '健康運動系は含めず、自然系は最大2単位。')
      ]
    end

    def integrated_check
      @credit.call('general_integrated', '総合・キャリア・琉大特色／地域創生', %w[integrated career regional], 2,
                   detail: '3区分の合計。各区分それぞれ2単位ではありません。')
    end

    def without_natural
      %w[humanities social integrated career regional]
    end

    def specified_checks
      requirements = @catalogue.requirements
      [
        @role.call('japanese', '日本語表現法入門', [[requirements.fetch('japanese_role')]]),
        @role.call('english_required', '指定英語科目', [requirements.fetch('english_roles')])
      ]
    end

    def foreign_language_check
      english = @ledger.sum(['english'])
      largest = @ledger.grouped_credits('foreign_language', 'language').values.max || Catalogue::ZERO
      satisfied = english >= 12 || (english >= 8 && largest >= 4)
      review = @ledger.uncertain?(%w[english foreign_language]) || @ledger.foreign_language_unknown
      Check.new(id: 'foreign_language', label: '外国語の選択経路', status: CreditCheck.status(satisfied, review),
                counted_credits: english, required_credits: nil, missing_courses: [], source: Catalogue::SOURCE,
                detail: foreign_language_detail(english, largest))
    end

    def foreign_language_detail(english, largest)
      "英語#{english.to_s('F')}単位、一外国語の最大#{largest.to_s('F')}単位。" \
        '英語12単位、または英語8単位＋同じ一外国語4単位。指定英語科目は別途必須。'
    end
  end
end

