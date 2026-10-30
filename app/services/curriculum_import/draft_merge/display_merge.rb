# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # 要件表のページの「画面の表」(display)の統合。章・行・小計を、このページの分だけ入れ直す。
    #
    # 人が直して残した章・小計は入れ直さず、人が消したものは戻さない。残したものと読んだものは、由来(Origins)で結ぶ
    # (id が付け替わっていても、同じものを見つける)。
    module DisplayMerge
      private

      def add_display(display, rule_ids)
        target = @document['display']
        total = !adopt_total_credits(display['total_credits']).nil?
        @rule_ids = rule_ids
        @row_ids = {}
        @row_taken = target['groups'].flat_map { |group| group['rows'].pluck('id') }
        groups = add_groups(display['groups'], target['groups'].pluck('id'))
        subtotals = add_subtotals(display['subtotals'], Array(target['subtotals']).pluck('id'))
        target['groups'].concat(groups)
        (target['subtotals'] ||= []).concat(subtotals) if subtotals.any?
        { groups: groups.pluck('id'), subtotals: subtotals.pluck('id'), total_credits: total }
      end

      def add_groups(items, taken)
        plan = @origins.match('groups', Array(items).pluck('id'), kept_ids('groups'))
        add_all(items, taken) { |group, index| add_group(group, plan[index], taken) }
      end

      def add_subtotals(items, taken)
        plan = @origins.match('subtotals', Array(items).pluck('id'), kept_ids('subtotals'))
        add_all(items, taken) { |subtotal, index| add_subtotal(subtotal, plan[index], taken) }
      end

      # このページの中で同じ id が2つあっても付け替えられるよう、付けた id を taken に積みながら足す。
      # ブロックが nil を返したもの(人が直して残した・人が消した)は足さない。
      def add_all(items, taken)
        Array(items).each_with_index.filter_map do |item, index|
          yield(item, index)&.tap { |added| taken << added['id'] }
        end
      end

      # 人が直して残した章は、行ごと入れない(直した行は、その章の中にある)。
      # ただし、あとの小計が指す行は、残した章の中で付けた id に結ぶ(付け替わっている行を指したままにしない)。
      def add_group(group, (origin, kept), taken)
        return keep_group(group, origin, kept) if kept

        group = group.merge('id' => unique_id(group['id'], taken))
        return if removed?('group', group['id'], origin)

        @origins.remember('groups', group['id'], origin)
        group['check_id'] = @rule_ids.fetch(group['check_id'], group['check_id']) if group['check_id']
        group['rows'] = Array(group['rows']).filter_map { |row| add_row(row, origin.first) }
        group
      end

      def keep_group(group, origin, kept)
        stored = @document['display']['groups'].find { |entry| entry['id'] == kept }
        rows = Array(stored&.dig('rows')).pluck('id')
        Array(group['rows']).each do |row|
          match = kept_row_id(rows, @origins.next('rows', origin.first, row['id']), row['id'])
          @row_ids[row['id']] ||= match if match
        end
        note_kept('章', @document['display']['groups'], kept, group)
      end

      # 残した章の中の、この行(由来が合うもの。記録が無ければ、付け替えの形を外した id が同じもの)の、付けた id。
      def kept_row_id(rows, origin, raw)
        rows.find { |id| @origins.recorded('rows', id) == origin } ||
          rows.find { |id| id.sub(/_p#{@page}(_\d+)?\z/, '') == raw }
      end

      # @row_taken には、既にある行と、このページで付けた行の id をすべて積む(同じ id が3つ以上あっても重ならない)。
      # 人が消した行は戻さない。行の由来は、章の読んだ id と合わせて持つ。
      def add_row(row, group_id)
        origin = @origins.next('rows', group_id, row['id'])
        id = unique_id(row['id'], @row_taken)
        @row_taken << id
        @row_ids[row['id']] ||= id
        return if removed?('row', id, origin)

        @origins.remember('rows', id, origin)
        row.merge('id' => id, 'check_ids' => remap(row['check_ids'], @rule_ids))
      end

      def add_subtotal(subtotal, (origin, kept), taken)
        return note_kept('小計', @document['display']['subtotals'], kept, subtotal) if kept

        id = unique_id(subtotal['id'], taken)
        return if removed?('subtotal', id, origin)

        @origins.remember('subtotals', id, origin)
        subtotal.merge('id' => id, 'row_ids' => remap(subtotal['row_ids'], @row_ids),
                       'check_ids' => remap(subtotal['check_ids'], @rule_ids))
      end

      # このページが定義した id だけを付け替える。別のページの規則を指す参照は、そのまま残す。
      def remap(references, mapping)
        Array(references).map { |reference| mapping.fetch(reference, reference) }
      end
    end
  end
end

