# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 画面に出す表(display)の突き合わせ。設計書 §5・§6 と §4 の 5(総単位)。
    #
    # display は学生が見る内訳そのもの。行が存在しない規則・区分を指していても画面は落ちず、見込みの数字が消えたり
    # 「不足」を描いたりする。落ちないぶん気づかれないので、公開の前に止める。
    class DisplayChecks < Checks
      def run
        total_credits
        references
        uncovered_categories
        required_credits_agree
        over_total
        total_rule
      end

      private

      def total_credits
        return if positive_number?(input.display['total_credits'])

        findings.blocking(:display, 'total_credits', '卒業に必要な総単位(display.total_credits)が読めていません。画面の「卒業まで」の数字が出せません。')
      end

      # check_id・check_ids・row_ids・categories は、画面が id で引く。引けなければ、その行は充足と判定されない。
      def references
        input.groups.each do |group|
          check_reference(group, 'check_id', Array.wrap(group['check_id']), "章「#{group['id']}」")
        end
        input.rows.each do |row|
          check_reference(row, 'check_ids', Array.wrap(row['check_ids']), "行「#{row['id']}」")
          unknown = Array.wrap(row['categories']) - input.category_keys
          next if unknown.empty?

          findings.blocking(:display, row['id'],
                            "行「#{row['id']}」が categories に無い区分を指しています: #{unknown.join('、')}。この行は区分の単位を数えられません。")
        end
        input.subtotals.each { |subtotal| subtotal_references(subtotal) }
      end

      def check_reference(item, field, ids, name)
        missing = ids - input.condition_ids
        return if missing.empty?

        findings.blocking(:display, item['id'], "#{name}の #{field} が指す規則が見つかりません: #{missing.join('、')}。" \
                                                '画面はこの行の判定と見込み算入を出せず、不足として描きます。')
      end

      def subtotal_references(subtotal)
        check_reference(subtotal, 'check_ids', Array.wrap(subtotal['check_ids']), "小計「#{subtotal['id']}」")
        missing = Array.wrap(subtotal['row_ids']) - input.rows.pluck('id')
        return if missing.empty?

        findings.blocking(:display, subtotal['id'],
                          "小計「#{subtotal['id']}」の row_ids が指す行が見つかりません: #{missing.join('、')}。小計がその行の単位を数えません。")
      end

      # どの行にも出てこない区分の科目は、計画表にも内訳にも出ず、学生から見えないまま消える。総単位に数えない区分
      # (exclude 規則が算入から外すもの)は、行に出なくてよい。
      def uncovered_categories
        shown = input.rows.flat_map { |row| Array.wrap(row['categories']) }
        (input.counted_category_keys - shown).each do |category|
          findings.blocking(:display, category, "区分「#{input.category_label(category)}」(#{category})は、画面のどの行にも出てきません。" \
                                                'この区分の科目は、計画表にも内訳にも出ないまま消えます。')
        end
      end

      # 章・行・小計の必要単位が、同じ画面が指す規則の必要単位と違えば、画面の数字と判定が食い違う。
      # 指す規則が1つのときだけ比べる(複数の規則を束ねる行は、どれと比べるか決まらない)。
      def required_credits_agree
        input.groups.each { |group| agree(group, Array.wrap(group['check_id']), "章「#{group['id']}」") }
        input.rows.each { |row| agree(row, Array.wrap(row['check_ids']), "行「#{row['id']}」") }
        input.subtotals.each { |subtotal| agree(subtotal, Array.wrap(subtotal['check_ids']), "小計「#{subtotal['id']}」") }
      end

      def agree(item, ids, name)
        return unless ids.one? && number?(item['required_credits'])

        rule = condition_for(ids.first)
        return unless rule && number?(rule['required_credits']) && rule['required_credits'] != item['required_credits']

        shown = format_number(item['required_credits'])
        judged = format_number(rule['required_credits'])
        findings.warning(:display, item['id'], "#{name}の必要単位(#{shown})が、規則「#{rule['id']}」の必要単位(#{judged})と違います。")
      end

      def condition_for(id)
        input.rules.find { |candidate| candidate['id'] == id && !input.adjustment?(candidate) }
      end

      # 設計書 §4 の 5。区分ごとの必要単位の合計が総単位を超えていれば、どれかの数字が誤っている。
      # 章の必要単位の合計と、区分1つだけを数える規則の必要単位の合計(同じ区分は大きい方を1回)の両方で見る。
      def over_total
        total = input.display['total_credits']
        return unless positive_number?(total)

        sums = { '章の必要単位の合計' => input.groups.sum do |group|
          number?(group['required_credits']) ? group['required_credits'] : 0
        end,
                 '区分ごとの必要単位の合計' => per_category_requirements.values.sum }
        sums.each do |name, sum|
          next unless sum > total

          findings.warning(:display, 'total_credits',
                           "#{name}(#{format_number(sum)})が、卒業算入の総単位(#{format_number(total)})を超えています。どちらかの数字が誤っています。")
        end
      end

      def per_category_requirements
        input.well_formed_nodes_of('credit_sum').select(&:top).each_with_object({}) do |node, required|
          categories = node.rule['categories']
          next unless categories.one?

          required[categories.first] = [required[categories.first], node.rule['required_credits']].compact.max
        end
      end

      # 卒業の総単位に当たる規則(必要単位が総単位と同じ credit_sum)が、総単位に数える区分と同じ区分を数えているか。
      # 足りなければ総単位が過少に、余れば過大に出る。総単位に数えない区分が混ざっても exclude が外すので、警告にとどめる。
      def total_rule
        total = input.display['total_credits']
        return unless positive_number?(total)

        candidates = input.well_formed_nodes_of('credit_sum').select do |node|
          node.top && node.rule['required_credits'] == total
        end
        counted = input.counted_category_keys
        if candidates.empty?
          return findings.warning(:display, 'total_credits', "卒業の総単位(#{format_number(total)})に当たる規則" \
                                                             '(必要単位が同じ credit_sum)がありません。総単位の判定が規則にありません。')
        end
        return if candidates.any? { |node| node.rule['categories'].sort == counted.sort }

        differences(candidates.first, counted)
      end

      def differences(node, counted)
        categories = node.rule['categories']
        missing = counted - categories
        extra = categories - counted
        detail = []
        detail << "足りない区分: #{missing.join('、')}(この区分の単位は総単位に数えられません)" if missing.any?
        detail << "余分な区分: #{extra.join('、')}(総単位に数えない区分です)" if extra.any?
        findings.warning(:rule, node.target, "総単位の規則が数える区分が、総単位に数える区分(counts_toward_total)と違います。#{detail.join('。')}。")
      end
    end
  end
end

