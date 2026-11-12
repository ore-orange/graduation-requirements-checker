# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 行・章を消したとき、その行だけが指していた決まりも消す(設計書 項目5)。
    #
    # 人は決まりの id を打たず、画面が結びつけを作る(RuleLinking)。行を消したときに決まりを残すと、
    # どの行にも出ない決まりが増えていく(判定には効いたまま)。
    # ほかの行・章・枠も指している決まりは残す。この保存で人が値を直した決まりも残す
    # (直した手で消えると、何が起きたか分からない)。
    module RuleCleanup
      private

      def discard_group(group, removed)
        claim_rules(Array(group['check_id']))
        Array(group['rows']).grep(Hash).each { |row| claim_rules(Array(row['check_ids'])) }
        discard(group, 'group', removed)
      end

      def discard_row(row, removed, group_id)
        claim_rules(Array(row['check_ids']))
        discard(row, 'row', removed, group_id)
      end

      def claim_rules(ids)
        (@orphan_candidates ||= []).concat(ids.grep(String))
      end

      # 消した行・章が指していた決まりのうち、残ったどの章・行・枠からも指されなくなったものを消す。
      def drop_orphaned_rules
        candidates = (@orphan_candidates || []).uniq - referenced_rule_ids - edited_rule_ids
        return if candidates.empty?

        rules = list_of(@document, 'rules') or return

        candidates.each { |id| drop_rule(rules, id) }
      end

      def drop_rule(rules, id)
        index = rules.index { |rule| rule['id'] == id }
        return unless index

        discard(rules.delete_at(index), 'rule', touch: false)
      end

      def edited_rule_ids = @touched.filter_map { |kind, id| id if kind == 'rule' }

      def referenced_rule_ids
        groups = display_groups
        from_rows = groups.flat_map do |group|
          Array(group['rows']).grep(Hash).flat_map { |row| Array(row['check_ids']) }
        end
        subtotals = Array(@document.dig('display', 'subtotals')).grep(Hash)
        (groups.flat_map { |group| Array(group['check_id']) } + from_rows +
         subtotals.flat_map { |item| Array(item['check_ids']) }).grep(String).uniq
      end
    end
  end
end

