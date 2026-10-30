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
        empty_required_categories
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
        input.rows.each { |row| row_references(row) }
        input.subtotals.each { |subtotal| subtotal_references(subtotal) }
      end

      def row_references(row)
        check_reference(row, 'check_ids', Array.wrap(row['check_ids']), "行「#{row['id']}」")
        unless row['categories'].is_a?(Array)
          return findings.blocking(:display, row['id'], "行「#{row['id']}」の categories が配列ではありません(空なら [] と書きます)。" \
                                                        '画面の計画表が、この行の区分を引けずに落ちます。')
        end

        unknown = row['categories'] - input.category_keys
        return if unknown.empty?

        findings.blocking(:display, row['id'],
                          "行「#{row['id']}」が categories に無い区分を指しています: #{unknown.join('、')}。この行は区分の単位を数えられません。")
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
        (input.counted_category_keys - shown_categories).each do |category|
          findings.blocking(:display, category, "区分「#{input.category_label(category)}」(#{category})は、画面のどの行にも出てきません。" \
                                                'この区分の科目は、計画表にも内訳にも出ないまま消えます。')
        end
      end

      # 行が出す区分。categories が空配列の行は、判定(check)から単位を取る credits_from_check の行なら正当な形。
      # その行は、指す規則が数える区分を出すものとして扱う。categories の欄そのものが無い・配列でない行は、
      # 画面(計画表・ダッシュボード)が categories.include? を呼んで落ちるので、references で別に止める。
      def shown_categories
        input.rows.flat_map do |row|
          categories = Array.wrap(row['categories'])
          next categories if categories.any? || row['credits_from_check'] != true || !row['categories'].is_a?(Array)

          Array.wrap(row['check_ids']).flat_map { |id| rule_categories(condition_for(id)) }
        end
      end

      def rule_categories(rule)
        return [] unless rule

        %w[category categories].flat_map { |field| Array.wrap(rule[field]) }.grep(String)
      end

      # 科目が1つも無い区分が、必要単位のある行に出ている。科目の読み落としで区分ごと消えたか、区分の綴りが違う疑い。
      # 公開は止めない。学生は任意の算入区分に自分で科目を入れられる(計画表の custom_categories)ので、科目表に無い区分が
      # 満たせないわけではなく、止めると、要件表が内数を明記した年度(専門科目(自由)の11単位など)を公開できなくなる。
      # 消えた区分の単位は数えられず、学生には不足・要確認と出る(安全側)ので、警告にとどめる。
      # 必要単位を持たない行(必要単位が null の内数の行)の区分は、学生が自由に入れるものとして許す。
      def empty_required_categories
        input.rows.each do |row|
          next unless positive_number?(row['required_credits']) && row['categories'].is_a?(Array)

          (row['categories'] & input.counted_category_keys).each do |category|
            next if input.courses_in(category).any?

            findings.warning(:display, row['id'], "行「#{row['id']}」は必要単位がありますが、区分「#{input.category_label(category)}」" \
                                                  "(#{category})に科目が1つもありません。読み落としで消えていると、この区分の単位は" \
                                                  'どの行にも届きません。')
          end
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

      # 設計書 §4 の 5。総単位より、章の必要単位の合計が大きいことはありえない。
      #
      # 章の合計: 章は互いに重ならない内訳なので、章ごとの最低単位の合計が総単位を超えるのは算術上の矛盾。
      #   総単位を低く読むと、総単位の規則は「充足」と答え、学生は足りないまま「卒業できます」と言われる(要確認にも
      #   ならない)。だから公開を止める。総単位が章の合計より大きいのは正当なので出さない。
      # 区分ごとの合計: 区分1つだけを数える規則の必要単位の合計(同じ区分は大きい方を1回)。総単位に数えない区分が
      #   独自の必要単位を持てるので、総単位を超えることが正当にありうる。警告にとどめる。
      def over_total
        total = input.display['total_credits']
        return unless positive_number?(total)

        chapters = input.groups.sum { |group| chapter_requirement(group) }
        report_over_total('章の必要単位の合計', chapters, total, blocking: true)
        report_over_total('区分ごとの必要単位の合計', per_category_requirements.values.sum, total, blocking: false)
      end

      # 総単位に数えない区分だけでできた章(教職科目など)は、総単位とは別に積める。合計に入れない。
      def chapter_requirement(group)
        return 0 unless number?(group['required_credits'])

        categories = Array.wrap(group['rows']).flat_map do |row|
          Array.wrap(row['categories']) if row.is_a?(Hash)
        end.compact
        uncounted_only = categories.any? && (categories - input.uncounted_category_keys).empty?
        uncounted_only ? 0 : group['required_credits']
      end

      def report_over_total(name, sum, total, blocking:)
        return unless sum > total

        reason = "#{name}(#{format_number(sum)})が、卒業算入の総単位(#{format_number(total)})を超えています。" \
                 'どちらかの数字が誤っています。'
        reason += '総単位が低く読まれていると、足りない学生に「卒業できます」と答えます。' if blocking
        if blocking
          findings.blocking(:display, 'total_credits',
                            reason)
        else
          findings.warning(:display, 'total_credits', reason)
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
      # 注意: 「余分な区分は警告でよい」のは、RuleChecks#excluded_categories が「総単位に数えない区分には必ず exclude 規則が
      # ある」ことを止めているから。あちらを警告に緩めると、ここの余分な区分は黙って過大に数えられる。両方を一緒に見ること。
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

