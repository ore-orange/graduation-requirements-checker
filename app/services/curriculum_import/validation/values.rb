# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 検査が値を読むときの共通の読み方。AI が書いた値は、型が違うことがある。
    module Values
      private

      def text?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def number?(value)
        value.is_a?(Numeric) && value.to_f.finite?
      end

      def positive_number?(value)
        number?(value) && value.positive?
      end

      # 単位の値。数でない・負・無限は nil(判定が単位として読むのと同じ読み方)。
      def decimal(value)
        GraduationAssessment::Ledger.decimal(value)
      end

      def format_number(value)
        value.to_d.then { |number| number.frac.zero? ? number.to_i.to_s : number.to_s('F') }
      end
    end
  end
end

