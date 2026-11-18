# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 検査が見つけた問題の入れ物。公開を止めるもの(blocking)と、人の目に留めるだけのもの(warning)を分ける。
    # 同じ問題を2つの検査が拾っても、画面には1行だけ出す。
    class Findings
      def initialize
        @items = []
      end

      # target は突き合わせ用の id(画面の箱・行に指摘を付けるのに使う)。人に見せる文字は label。
      # label を渡さなければ target をそのまま見せる(id でない target = ページ名などのとき)。
      def blocking(scope, target, reason, label: nil)
        add(scope, target, reason, true, label)
      end

      def warning(scope, target, reason, label: nil)
        add(scope, target, reason, false, label)
      end

      def blocking?
        @items.any? { |item| item[:blocking] }
      end

      def to_a
        @items.uniq.freeze
      end

      private

      def add(scope, target, reason, blocking, label)
        @items << { scope: scope, target: target.to_s, label: (label.presence || target).to_s, reason: reason,
                    blocking: blocking }
      end
    end
  end
end

