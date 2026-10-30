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
    #
    # 由来の記録が無い(この記録を足す前の下書き)・読み直しで同じ id の数が減った、のときは、由来で結べない。
    # その場合は、付け替えの形(_p<ページ>、_p<ページ>_<n>)を外した id が読んだ id と同じものを、順に結ぶ。
    # 別の読んだ id とは、決して結ばない。
    class Origins
      KINDS = %w[rules groups subtotals rows].freeze

      def initialize(previous, page)
        @previous = previous.is_a?(Hash) ? previous : {}
        @page = page
        @current = KINDS.index_with { {} }
        @seen = Hash.new(0)
      end

      # 答えの kind の項目(読んだ id の並び raws)を、前に付けた id(stored_ids)のうち人が直して残したものと結ぶ。
      # 戻り値は、項目ごとの [由来, 結んだ前の id か nil]。由来が正確に合うものを先に結び、残りを形で結ぶ
      # (先に形で結ぶと、あとの項目の正確な相手を取ってしまう)。
      def match(kind, raws, stored_ids)
        origins = occurrences(raws)
        claimed = []
        exact = origins.map { |origin| claim(stored_ids, claimed) { |stored| previous_of(kind, stored) == origin } }
        exact.each_with_index.map do |stored, index|
          [origins[index], stored || claim(stored_ids, claimed) { |candidate| unsuffixed(candidate) == raws[index] }]
        end
      end

      # 行の由来のように、答えの中で順に出てくるものの、次の由来。
      def next(kind, *raw)
        count = @seen[[kind, raw]]
        @seen[[kind, raw]] += 1
        [*raw, count]
      end

      # 前に付けた id(stored)の由来。記録が無いものは nil。
      def recorded(kind, stored)
        @previous.dig(kind, stored)
      end

      def remember(kind, stored, origin)
        @current[kind][stored] = origin
      end

      # 次の記録。残したもの(kept: Withdrawal が引き継いだ由来)と、今回足したものを合わせる。
      def record(kept)
        KINDS.index_with { |kind| Hash(kept&.dig(kind)).merge(@current[kind]) }.reject { |_, table| table.empty? }
      end

      private

      # 記録が無いものは、その id 自身が読んだ id だったものとする(付け替えの無かった古い下書き)。
      def previous_of(kind, stored)
        recorded(kind, stored) || [stored, 0]
      end

      def occurrences(raws)
        counts = Hash.new(0)
        raws.map { |raw| [raw, counts[raw]].tap { counts[raw] += 1 } }
      end

      # 前の id のうち、まだ結んでおらず、ブロックに合う最初のものを結ぶ。
      def claim(stored_ids, claimed)
        found = stored_ids.find { |stored| claimed.exclude?(stored) && yield(stored) }
        claimed << found if found
        found
      end

      # 付け替えの形を外した id。
      def unsuffixed(stored)
        stored.sub(/_p#{@page}(_\d+)?\z/, '')
      end
    end
  end
end

