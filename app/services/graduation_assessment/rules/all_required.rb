# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 科目表の必修科目をすべて修得しているかを見る。余剰単位による代用は認めない。
    class AllRequired < Base
      def evaluate(catalogue, ledger)
        mandatory = catalogue.mandatory
        missing = mandatory.reject { |course| ledger.acquired?(course) }
        mismatch = table_mismatch?(mandatory)
        uncertain = missing.pluck('key').intersect?(ledger.uncertain_required)
        Outcome.new(satisfied: missing.empty? && !mismatch,
                    review: mismatch || ledger.unknown_identity || uncertain,
                    counted: ledger.sum(mandatory.pluck('category').uniq), missing: missing.pluck('name'))
      end

      private

      # 科目表の転記漏れを、必修の科目数・単位合計・区分が便覧の値と合うかで見張る。
      def table_mismatch?(mandatory)
        credits = mandatory.sum(Catalogue::ZERO) { |course| Ledger.decimal(course['credits']) || Catalogue::ZERO }
        mandatory.size != definition.fetch('expected_course_count') ||
          credits != BigDecimal(definition.fetch('required_credits').to_s) ||
          miscategorised?(mandatory)
      end

      # 必修の科目が必修の区分の外に入っていると、科目数も単位合計も合ったまま通り、
      # その単位が選択の集計にも流れ込んで二重に数えられる。区分の取り違えは充足ではなく要確認にする。
      def miscategorised?(mandatory)
        allowed = definition['required_categories']
        return false if allowed.nil?

        mandatory.any? { |course| allowed.exclude?(course['category']) }
      end

      def detail(catalogue, outcome, _status)
        count = catalogue.mandatory.size
        "#{definition.fetch('expected_course_count')}科目それぞれの修得を確認。" \
          "科目表の必修#{count}科目中#{count - outcome.missing.size}科目を確認。#{definition['detail']}"
      end
    end
  end
end

