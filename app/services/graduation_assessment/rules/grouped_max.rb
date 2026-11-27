# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 区分の算入単位を科目の欄の値でグループに分け、最大のグループが必要単位に届くか。グループどうしは合算しない。
    # 例: 同じ他コースが提供する工学融合から4単位(group_by: field:provider)、同じ一外国語から4単位(field:language)。
    #
    # 欄が空でグループを決められない科目は、最大値に数えず、missing_group_note を注記して要確認にする。
    class GroupedMax < Base
      FIELD_PREFIX = 'field:'

      def initialize(definition)
        super
        group_by = definition.fetch('group_by').to_s
        raise ArgumentError, "grouped_max の group_by は field:<欄名> にしてください: #{group_by}" unless
          group_by.start_with?(FIELD_PREFIX) && group_by.length > FIELD_PREFIX.length
      end

      def category = definition.fetch('category')
      def field = definition.fetch('group_by').delete_prefix(FIELD_PREFIX)
      def missing_group_note = definition.fetch('missing_group_note')
      # グループを決められない科目があったことを、評価ごとに ledger へ残すときの鍵。
      def group_key = "#{category}|#{field}"
      def grouped_rules = [self]

      def outcome(_catalogue, ledger)
        counted = ledger.grouped_credits(category, field).values.max || Catalogue::ZERO
        Outcome.new(satisfied: counted >= definition.fetch('required_credits'),
                    review: ledger.unknown_groups.include?(group_key) || ledger.uncertain?([category]),
                    counted: counted)
      end

      def check(catalogue, ledger) = credit_check(catalogue, ledger)

      def counted_values(catalogue, ledger)
        id ? { id => outcome(catalogue, ledger).counted } : {}
      end
    end
  end
end

