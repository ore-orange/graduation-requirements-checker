# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 検査が見つけた問題の入れ物。公開を止めるもの(blocking)と、人の目に留めるだけのもの(warning)を分ける。
    # 同じ問題を2つの検査が拾っても、画面には1行だけ出す。
    class Findings
      def initialize
        @items = []
      end

      def blocking(scope, target, reason)
        add(scope, target, reason, true)
      end

      def warning(scope, target, reason)
        add(scope, target, reason, false)
      end

      def blocking?
        @items.any? { |item| item[:blocking] }
      end

      def to_a
        @items.uniq.freeze
      end

      private

      def add(scope, target, reason, blocking)
        @items << { scope: scope, target: target.to_s, reason: reason, blocking: blocking }
      end
    end
  end
end

