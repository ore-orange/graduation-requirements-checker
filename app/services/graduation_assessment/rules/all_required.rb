# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 科目表で required の科目を、すべて修得しているか。余剰単位による代用は認めない。
    #
    # expected_course_count・required_categories は、科目表の転記漏れを見張るための控え。必修の数が合わない、
    # または必修の科目が required_categories の外の区分にあるときは、不足ではなく要確認にする。
    class AllRequired < Base
      def check(catalogue, ledger)
        mandatory = catalogue.mandatory
        missing = mandatory.reject { |course| ledger.acquired?(course) }
        metadata_missing = metadata_missing?(mandatory)
        unknown = metadata_missing || ledger.unknown_identity ||
                  missing.pluck('key').intersect?(ledger.uncertain_required)
        status = Rules.status(missing.empty? && !metadata_missing, unknown)
        build_check(status: status, counted: ledger.sum(categories), required: definition.fetch('required_credits'),
                    missing: missing.pluck('name'), detail: detail(mandatory.size, missing.size))
      end

      private

      def categories = definition.fetch('required_categories')
      def expected = definition.fetch('expected_course_count')

      def metadata_missing?(mandatory)
        mandatory.size != expected || mandatory.any? { |course| categories.exclude?(course['category']) }
      end

      def detail(count, missing)
        "#{expected}科目それぞれの修得を確認。科目表の必修#{count}科目中#{count - missing}科目を確認。" \
          "#{definition['detail']}"
      end
    end
  end
end

