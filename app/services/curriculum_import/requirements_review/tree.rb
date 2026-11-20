# frozen_string_literal: true

module CurriculumImport
  class RequirementsReview
    # 確認画面のツリー。章の中身を、画面に描く順の節点(行と枠)にする。
    #
    # 文書の形は変えないので、次の2つは「文書のどこにあるか」ではなく「画面のどこに出すか」をここで決める。
    #
    #  - 小計(display.subtotals)は、まとめている行を囲む枠にする(設計書 項目10)。row_ids が指す行が1つの章の中で
    #    連続しているときだけ囲める。連続していない小計は枠にできないので、章の後ろに並べる(loose_subtotals)。
    #  - 算入上限(cap)は、その区分を数える行の内側に出す(設計書 項目4)。cap は台帳全体に掛かる調整で、
    #    行にも章にも閉じていないが、見つけやすさのために、その区分を数えている行の中に置く。
    #    どの行の区分にも当たらない上限は、どこにも出ないと見えなくなるので、ここでは拾わず、
    #    「どの行にも結びついていない決まり」の枠に残す(設計書 項目6)。
    class Tree
      # 行を囲む枠。小計1つと、それがまとめている連続した行。
      # index は display.subtotals の中の位置、row_index は囲んだ最初の行が章の中で何番目か(どちらも欄の名前に使う)。
      Frame = Struct.new(:subtotal, :rows, :index, :row_index, keyword_init: true) do
        def id = subtotal['id']
      end

      def initialize(input)
        @input = input
      end

      # 章(group_index 番目)の中身を、画面に描く順に並べた [節点, 行の位置] の組。節点は行(Hash)か枠(Frame)。
      # 行の位置は、その章の rows の中の添字(枠なら、囲んだ最初の行の添字)。フォームの欄の名前に使う。
      def nodes_of(group_index)
        rows = rows_of(group_index)
        starts = frames.fetch(group_index, {})
        nodes = []
        index = 0
        while index < rows.size
          frame = starts[index]
          nodes << [frame || rows[index], index]
          index += frame ? frame.rows.size : 1
        end
        nodes
      end

      # 枠にできなかった小計と、display.subtotals の中の位置の組。
      # (まとめている行が1つの章の中で連続していない、この便覧に無い行を指している、row_ids が空)
      def loose_subtotals
        framed = framed_ids
        @input.subtotals.each_with_index.reject { |subtotal, _| framed.include?(subtotal['id']) }
      end

      def framed_ids
        frames.values.flat_map(&:values).map(&:id)
      end

      # この行の内側に出す算入上限の決まり。
      def caps_of(row) = caps.fetch(row['id'], [])

      private

      def rows_of(group_index)
        group = @input.groups[group_index]
        Array(group.is_a?(Hash) ? group['rows'] : nil).grep(Hash)
      end

      # 章ごとの { 枠が始まる行の位置 => Frame }。1つの行は1つの枠にしか入らない(先に来た小計が取る)。
      def frames
        @frames ||= build_frames
      end

      def build_frames
        taken = []
        @input.groups.each_index.index_with { |index| frames_in(rows_of(index), taken) }
      end

      def frames_in(rows, taken)
        ids = rows.pluck('id')
        @input.subtotals.each_with_index.with_object({}) do |(subtotal, position), starts|
          row_ids = Array(subtotal['row_ids']).grep(String)
          next if row_ids.empty? || row_ids.intersect?(taken)

          first = ids.index(row_ids.first)
          next unless first && ids[first, row_ids.size] == row_ids

          taken.concat(row_ids)
          starts[first] = Frame.new(subtotal: subtotal, rows: rows[first, row_ids.size], index: position,
                                    row_index: first)
        end
      end

      def caps
        @caps ||= build_caps
      end

      def build_caps
        @input.rules.select { |rule| rule['type'] == 'cap' }.each_with_object({}) do |cap, map|
          row = @input.rows.find { |candidate| Array(candidate['categories']).include?(cap['category']) }
          next unless row

          (map[row['id']] ||= []) << cap
        end
      end
    end
  end
end

