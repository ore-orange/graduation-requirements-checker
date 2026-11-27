# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 当たった科目を算入の対象にしない調整。category が一致し、field があればその欄も value と一致した科目に当たる。
    # 例: 自コースが提供する工学融合(category: fusion, field: provider, value: intelligent_informatics)。
    class Exclude
      attr_reader :reason

      def initialize(definition)
        @category = definition.fetch('category')
        @field = definition['field']
        @value = definition['value']
        @reason = definition.fetch('reason')
        raise ArgumentError, 'exclude の reason が空です' if @reason.blank?
        raise ArgumentError, 'exclude の field には value も書いてください' if @field.present? && @value.blank?
      end

      def match?(course)
        course['category'] == @category && (@field.blank? || course[@field] == @value)
      end
    end
  end
end

