# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # 規則・章・小計・行が、読み取りの答えのどれから来たかの記録(由来)。
    #
    # 文書に入る id は、別のページの id とぶつかると付け替わる(common_total → common_total_p4)。読み直しで人が直した
    # ものを見つけるには、答えの側の id(読んだ id)ではなく、前に付けた id と結びつける必要がある。読んだ id だけで
    # 照らすと、付け替わったものは一致せず、直した規則と AI の読みが並び、直した行が AI の規則を指してしまう。
    #
    # 由来は「読んだ id と、その答えの中で何番目に出たか」。同じ答えの中に同じ id が2つあっても区別できる。
    # 行は章の読んだ id も含める。記録は付けた id から由来を引く表で、ページの contributed['origins'] に持つ。
    class Origins
      KINDS = %w[rules groups subtotals rows].freeze

      def initialize(previous)
        @previous = previous.is_a?(Hash) ? previous : {}
        @current = KINDS.index_with { {} }
        @seen = Hash.new(0)
      end

      # 今回の答えで、kind の raw(読んだ id)の出現を数え、由来を返す。
      def next(kind, *raw)
        count = @seen[[kind, raw]]
        @seen[[kind, raw]] += 1
        [*raw, count]
      end

      # 前に付けた id(stored)の由来。記録が無い(古い)ものは、その id 自身が読んだ id だったものとする。
      def previous_of(kind, stored)
        @previous.dig(kind, stored) || [stored, 0]
      end

      def remember(kind, stored, origin)
        @current[kind][stored] = origin
      end

      # 次の記録。残したもの(kept: Withdrawal が引き継いだ由来)と、今回足したものを合わせる。
      def record(kept)
        KINDS.index_with { |kind| Hash(kept&.dig(kind)).merge(@current[kind]) }.reject { |_, table| table.empty? }
      end
    end
  end
end

