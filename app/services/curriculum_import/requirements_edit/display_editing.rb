# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 画面の表(display)の修正。総単位・章・行・小計の値と、章と行の並び。
    module DisplayEditing
      private

      def edit_display
        section = @params[:display]
        return if section.nil?
        return error('display の形が違います。') unless section.is_a?(Hash)

        @document['display'] = {} if @document['display'].nil?
        display = @document['display']
        return error('display はハッシュでなければなりません。') unless display.is_a?(Hash)

        edit_total_credits(display, section)
        edit_groups(display, section[:groups])
        edit_subtotals(display, section[:subtotals])
      end

      # 総単位は値そのもので、印を持てない。直したら、その値を足したページの記録から外す(読み直しが消さない)。
      def edit_total_credits(display, section)
        return unless section.key?(:total_credits)

        value = in_context('total', 'total') { coerce(section[:total_credits], :number, '卒業に必要な総単位') }
        return if value.nil? || value == :invalid || value == display['total_credits']

        display['total_credits'] = value
        release_total_credits
        @edited += 1
      end

      def release_total_credits
        @pages.each do |page|
          next unless page.dig('contributed', 'total_credits')

          page['contributed'] = page['contributed'].merge('total_credits' => DraftMerge::HUMAN)
        end
      end

      def edit_groups(display, value)
        entries = entries(value, 'display.groups') or return
        groups = list_of(display, 'groups') or return

        removed = []
        merged = merge_in_order(groups, entries, '章', 'group') do |group, entry|
          destroy?(entry) ? discard_group(group, removed) : edit_group(group, entry)
        end
        display['groups'] = merged
        mark_moved(groups.reject { |group| removed.include?(group['id']) }, merged)
      end

      def edit_group(group, entry)
        group = group.deep_dup
        mark(group, assign(group, entry, GROUP_FIELDS, 'group', group['id']).any?)
        edit_rows(group, entry[:rows]) if entry.key?(:rows)
        group
      end

      def edit_rows(group, value)
        entries = entries(value, "章「#{group['id']}」の rows") or return
        rows = list_of(group, 'rows') or return

        removed = []
        merged = merge_in_order(rows, entries, "行(章「#{group['id']}」)", 'row') do |row, entry|
          next discard_row(row, removed, group['id']) if destroy?(entry)

          row.deep_dup.tap { |copy| mark(copy, assign(copy, entry, ROW_FIELDS, 'row', row['id']).any?) }
        end
        group['rows'] = merged
        mark_moved(rows.reject { |row| removed.include?(row['id']) }, merged)
      end

      def edit_subtotals(display, value)
        entries = entries(value, 'display.subtotals') or return
        subtotals = list_of(display, 'subtotals') or return

        removed = []
        merged = merge_in_order(subtotals, entries, '小計', 'subtotal') do |subtotal, entry|
          next discard(subtotal, 'subtotal', removed) if destroy?(entry)

          subtotal.deep_dup.tap do |copy|
            mark(copy, assign(copy, entry, SUBTOTAL_FIELDS, 'subtotal', subtotal['id']).any?)
          end
        end
        display['subtotals'] = merged
      end

      # entries に出てきた項目を、entries の順(position があればその順)に並べ直す。出てこなかった項目は、消さず、動かさない。
      # 並べ直すのは、出てきた項目が元いた場所の中だけ(一部だけを送っても、ほかの項目の並びは変わらない)。
      # ブロックは (項目, 送られた値) を受けて、直した項目(消すなら nil)を返す。
      def merge_in_order(items, entries, noun, kind, &)
        by_id = items.group_by { |item| item['id'] }
        seen = []
        replacements = ordered(entries).filter_map do |entry|
          item = by_id[entry[:id]]&.first
          next error("#{noun}「#{entry[:id]}」は下書きにありません。", kind, entry[:id]) unless item

          seen << item['id']
          yield(item, entry)
        end
        fill_slots(items, seen, replacements)
      end

      def ordered(entries)
        entries.each_with_index.sort_by { |entry, index| [position(entry) || (index + 1), index] }.map(&:first)
      end

      # 出てきた項目の元の場所に、直した項目を並びの順に入れる。消した項目の場所は詰める。
      def fill_slots(items, seen, replacements)
        slots = items.each_index.select { |index| seen.include?(items[index]['id']) }
        merged = items.dup
        slots.each_with_index { |slot, index| merged[slot] = replacements[index] }
        merged.compact
      end

      # 位置が変わったものを、人が直したものとする。消したものを除いた相対の順で比べる。
      def mark_moved(before, after)
        order = before.pluck('id')
        after_ids = after.pluck('id')
        after.each do |item|
          mark(item, true) unless order.index(item['id']) == after_ids.index(item['id'])
        end
      end

      def position(entry)
        Float(entry[:position].to_s, exception: false)
      end
    end
  end
end

