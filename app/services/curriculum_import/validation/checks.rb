# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 検査のまとまりの共通部分。1つの Checks は入力を読み、見つけたものを findings に足す。
    class Checks
      include Values

      def initialize(input, findings)
        @input = input
        @findings = findings
      end

      def run
        raise NotImplementedError, "#{self.class}#run"
      end

      private

      attr_reader :input, :findings
    end
  end
end

