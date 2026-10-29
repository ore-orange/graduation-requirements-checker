# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 算入の対象にしない科目を決める調整。区分で指定し、number_prefix があれば科目番号の接頭辞も一致したものに絞る。
    # 科目番号が読めない科目は接頭辞の規則に当たらない。読めないことは、その接頭辞に属する根拠にならない。
    class Exclude
      attr_reader :definition

      def initialize(definition)
        @definition = definition
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

      def prefix_match?(course)
        prefix = CourseNumber.prefix(course['number'])
        !prefix.nil? && prefix == definition['number_prefix']
      end
    end
  end
end

