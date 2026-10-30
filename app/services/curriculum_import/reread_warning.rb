# frozen_string_literal: true

module CurriculumImport
  # 「読み直す」を押す前に出す確認の文。そのページを読み直すと、人が直したものがどうなるかを先に言う。
  #
  # 人が直した規則・章・行・小計は、読み直しでも残る(DraftMerge)。ただし、読み直した側の値は採られない。
  # 読み直しで AI の読みに戻ると思って直しを諦める人にも、残ると思って読み直す人にも、実際に起きることを見せる。
  # 直したものも消したものも無いページには、何も出さない(毎回の確認は、読み流されて意味を失う)。
  module RereadWarning
    SHOWN = 8

    module_function

    # 確認の文。出すことが無ければ nil。
    def for(document, page)
      return unless document.is_a?(Hash) && page.is_a?(Hash)

      contributed = page['contributed'] || {}
      kept = kept_items(document, contributed)
      removed = removed_items(document, page['page'])
      return if kept.empty? && removed.empty?

      text(page['page'], kept, removed)
    end

    def kept_items(document, contributed)
      display = document['display'].is_a?(Hash) ? document['display'] : {}
      groups = edited(display['groups'], contributed['groups'])
      rows = groups.flat_map { |group| Array(group['rows']).grep(Hash).select { |row| row[DraftMerge::CONFIRMED] == true } }
      [['規則', names(edited(document['rules'], contributed['rules']))], ['章', names(groups, 'title')],
       ['行', names(rows)], ['小計', names(edited(display['subtotals'], contributed['subtotals']))]]
        .reject { |_, list| list.empty? }
    end

    # list のうち、ids に挙がっていて、人が直したもの。章は行のどれかが直されていれば直した章。
    def edited(list, ids)
      Array(list).grep(Hash).select do |item|
        Array(ids).include?(item['id']) &&
          (item[DraftMerge::CONFIRMED] == true || Array(item['rows']).grep(Hash).any? do |row|
            row[DraftMerge::CONFIRMED] == true
          end)
      end
    end

    def names(items, field = 'label')
      items.map do |item|
        name = item[field] || item['name']
        name.present? ? "#{name}(#{item['id']})" : item['id'].to_s
      end
    end

    def removed_items(document, number)
      Array(document[DraftMerge::REMOVED]).grep(Hash).select { |entry| entry['page'] == number }
                                          .map do |entry|
        "#{KIND_NAMES.fetch(entry['kind'],
                            entry['kind'])}「#{entry['id']}」"
      end
    end

    KIND_NAMES = { 'rule' => '規則', 'group' => '章', 'row' => '行', 'subtotal' => '小計' }.freeze

    def text(number, kept, removed)
      lines = ["#{number}ページを読み直します。"]
      if kept.any?
        lines << '人が直した次の項目は、読み直した結果では上書きせず、そのまま残します(読み直した値が違えば、このページの警告に出ます)。' \
                 "#{kept.map { |noun, list| "#{noun}: #{summary(list)}" }.join(' / ')}。" \
                 '直した行を含む章は、直していない行も含めて、章ごと残ります。'
      end
      lines << "人が消した次の項目は、読み直しても戻しません: #{summary(removed)}。" if removed.any?
      lines << 'このページが足した、それ以外の規則・章・行は、読み直した結果に入れ替わります。よろしいですか?'
      lines.join("\n")
    end

    def summary(list)
      rest = list.size - SHOWN
      "#{list.first(SHOWN).join('・')}#{"ほか#{rest}件" if rest.positive?}"
    end
  end
end

