# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 決まりと、章・枠・行の結びつけ(設計書 項目5)。
    #
    # 人は規則の id を一度も打たない。画面は「結びつける先」を章・枠・行の名前で選ばせ、送るのは "種類:id"。
    # id はここが裏で振る(その章・枠・行の id から作る。<行の id>_c1 のような形)。
    #
    # 章の check_id は単数なので、すでに決まりを持つ章には結びつけられない(断る)。文書の形は変えない
    # (配列にすると、公開済みの便覧が持てる欄の形が変わる)。
    module RuleLinking
      LINK_KINDS = %w[group subtotal row].freeze

      private

      # 送られた "種類:id" を [種類, id] にする。空なら nil。読めない形なら問題を積む。
      def parse_link(value)
        text = value.to_s.strip
        return if text.empty?

        kind, id = text.split(':', 2)
        return error("決まりを結びつける先が読めません: #{text.first(40)}。") unless LINK_KINDS.include?(kind) && id.present?

        [kind, id]
      end

      # 決まりを、章・枠・行に結びつける。結びつけたものには印を付ける(読み直しで外れない)。
      # 戻り値は、結びつけられなかったときの問題の文(結びついたときは nil)。
      def link_rule(link, rule_id)
        kind, id = link
        owner = find_link_owner(kind, id) or return "結びつける先の#{KIND_NAMES.fetch(kind)}「#{id}」が下書きにありません。"

        if kind == 'group'
          return "章「#{owner['title']}」は、すでに決まり「#{owner['check_id']}」を確かめています。" if owner['check_id'].present?

          owner['check_id'] = rule_id
        else
          ids = Array(owner['check_ids']).grep(String)
          return if ids.include?(rule_id)

          owner['check_ids'] = ids + [rule_id]
        end
        mark(owner, true)
        nil
      end

      def find_link_owner(kind, id)
        case kind
        when 'group' then display_groups.find { |group| group['id'] == id }
        when 'subtotal' then Array(@document.dig('display', 'subtotals')).grep(Hash).find { |item| item['id'] == id }
        when 'row' then display_rows.find { |row| row['id'] == id }
        end
      end

      def display_groups = Array(@document.dig('display', 'groups')).grep(Hash)

      def display_rows = display_groups.flat_map { |group| Array(group['rows']).grep(Hash) }

      # 人が足す決まりの id。結びつける先があれば、その id から作る(<行の id>_c1)。無ければ added_rule_N。
      # 既にある id・人が消した id とは重ならないようにする。
      def new_rule_id(link)
        taken = Array(@document['rules']).grep(Hash).pluck('id')
        base = link ? "#{link.last}_c" : 'added_rule_'
        id = (1..).lazy.map { |number| "#{base}#{number}" }.find { |candidate| taken.exclude?(candidate) }
        clear_removed('rule', id)
        id
      end
    end
  end
end

