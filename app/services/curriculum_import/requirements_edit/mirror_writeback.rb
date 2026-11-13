# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 持ち主(行・章・枠・総単位の枠)の値を、その持ち主が隠している決まりにも書く(設計書 項目2)。
    #
    # なぜ要るか。`display.rows[].required_credits` は学生の画面に出す数字で、判定は
    # `rules[].required_credits` を見る。だから「情報技術系 2単位」を3に直して保存しても、
    # 学生の判定は2単位のままだった。両方を直さないといけないのに、画面はそれを教えてくれない。
    # 画面が重複した箱を消す(設計書 項目1)なら、その欄は持ち主が書く側になる。
    #
    # **どれを書き戻すかは、画面が描いたときの文書(編集前)で決める。** 編集後の文書で判じると、
    # 人が行の単位を直した時点で持ち主と決まりが食い違い、「同じことを言っていない」ことになって
    # 書き戻しが起きない。人が見ていた画面で箱が隠れていた決まりが、書き戻す相手。
    #
    # 走るのは edit_rules・edit_display・行や章を足したあと。先に走ると、同じ保存の中で人が直した
    # 決まりを上書きしてしまう。
    module MirrorWriteback
      private

      def mirror_writeback
        return unless @document['display'].is_a?(Hash)

        targets = mirrored_targets
        return if targets.empty?

        input = Validation::Input.new(@document, @pages)
        mirror = RequirementsReview::Mirror.new(input)
        targets.each { |id, (kind, owner_id)| write_back(input, mirror, id, kind, owner_id) }
      end

      # 画面が箱を隠していた決まり。編集前の文書で決める。
      # 人がこの保存で直接直した決まりは除く(箱が出ていたということなので、そちらを優先する)。
      def mirrored_targets
        before = @curriculum.document
        return {} unless before.is_a?(Hash)

        input = Validation::Input.new(before, @curriculum.pages)
        mirror = RequirementsReview::Mirror.new(input)
        mirror.owners(RequirementsReview::Tree.new(input)).except(*edited_rule_ids)
      end

      def edited_rule_ids
        @edited_rule_ids ||= entries(@params[:rules], 'rules').to_a.filter_map { |entry| entry[:id] }
      end

      # いまの文書での持ち主と決まりを引き、持ち主の値を決まりに書く。
      # どちらかが消えていれば(行を消した保存など)、何もしない。
      def write_back(input, mirror, id, kind, owner_id)
        rule = @document['rules'].grep(Hash).find { |candidate| candidate['id'] == id }
        return unless rule

        owner = owner_now(input, kind, owner_id)
        return if owner.nil? && kind != :total

        before = rule.slice('required_credits', 'categories')
        apply(rule, owner_credits(input, kind, owner), owner_categories(input, mirror, kind, owner))
        mark(rule, rule.slice('required_credits', 'categories') != before)
      end

      # 単位は数として、区分は集合として比べてから書く。
      # 実データには、同じ単位を 2 と 2.0 で持つ決まりや、同じ区分を違う並びで持つ決まりがある
      # (行は 人文・社会・自然・総合…、決まりは 人文・社会・総合…・自然)。書き方の違いで書き換えると、
      # 「触らずに保存しても、文書が1バイトも変わらない」が壊れる。
      def apply(rule, credits, categories)
        rule['required_credits'] = credits if credits_differ?(rule, credits)
        rule['categories'] = categories if categories_differ?(rule, categories)
      end

      def credits_differ?(rule, value)
        return false if value.nil?

        wanted = GraduationAssessment::Ledger.decimal(value)
        !wanted.nil? && GraduationAssessment::Ledger.decimal(rule['required_credits']) != wanted
      end

      def categories_differ?(rule, value)
        return false if value.nil?

        Array(rule['categories']).grep(String).uniq.sort != Array(value).grep(String).uniq.sort
      end

      def owner_now(input, kind, owner_id)
        case kind
        when :row then input.rows.find { |row| row['id'] == owner_id }
        when :group then input.groups.find { |group| group['id'] == owner_id }
        when :frame then input.subtotals.find { |subtotal| subtotal['id'] == owner_id }
        end
      end

      def owner_credits(input, kind, owner)
        kind == :total ? input.display['total_credits'] : owner['required_credits']
      end

      # 枠の持ち主は小計(Hash)で引いてくるので、Mirror が待っている Frame ではない。
      # 小計が指す行から、同じ合併を作る。
      def owner_categories(input, mirror, kind, owner)
        return mirror.counted_categories(kind, owner) unless kind == :frame

        ids = Array(owner['row_ids']).grep(String)
        input.rows.select { |row| ids.include?(row['id']) }
             .flat_map { |row| Array(row['categories']).grep(String) }.uniq
      end
    end
  end
end

