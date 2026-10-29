# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 算入の対象にしない科目を決める調整。区分で指定し、number_prefix があれば科目番号の接頭辞も一致したものに絞る。
    # 科目番号が読めない科目は接頭辞の規則に当たらない。読めないことは、その接頭辞に属する根拠にならない。
    class Exclude
      attr_reader :definition

      # 当たらないまま通る壊れた規則を作らないよう、読み込み時に定義を検める。
      def initialize(definition)
        @definition = definition
        require_text('category')
        require_text('reason')
        validate_number_prefix
      end

      def id
        definition.fetch('id')
      end

      # 当たる科目には理由を、当たらない科目には nil を返す。
      def reason_for(course)
        return unless course['category'] == definition.fetch('category')
        return if definition.key?('number_prefix') && !prefix_match?(course)

        definition.fetch('reason')
      end

      private

      def require_text(field)
        value = definition[field]
        return if value.is_a?(String) && !value.empty?

        raise ArgumentError, "exclude の#{field}は空でない文字列でなければなりません: #{value.inspect}"
      end

      # 科目側の番号は CourseNumber.prefix が空白や全角を整えて読む。定義側も同じ整え方で変わらない値でなければ、
      # 一致しないまま黙って何も除外しなくなる。
      def validate_number_prefix
        return unless definition.key?('number_prefix')

        value = definition['number_prefix']
        return if value.is_a?(String) && CourseNumber.prefix("#{value}1") == value

        raise ArgumentError, "exclude の number_prefix は空白や全角を含まない接頭辞でなければなりません: #{value.inspect}"
      end

      def prefix_match?(course)
        prefix = CourseNumber.prefix(course['number'])
        !prefix.nil? && prefix == definition['number_prefix']
      end
    end
  end
end

