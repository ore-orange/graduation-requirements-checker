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
      reverted = reverted_courses(document, contributed)
      return if kept.empty? && removed.empty? && reverted.empty?

      text(page['page'], kept, removed, reverted)
    end

    def kept_items(document, contributed)
      display = document['display'].is_a?(Hash) ? document['display'] : {}
      groups = edited(display['groups'], contributed['groups'])
      rows = groups.flat_map { |group| Array(group['rows']).grep(Hash).select { |row| row[DraftMerge::CONFIRMED] == true } }
      [['科目', course_names(document, contributed)], ['規則', names(edited(document['rules'], contributed['rules']))],
       ['章', names(groups, 'title')],
       ['行', names(rows)], ['小計', names(edited(display['subtotals'], contributed['subtotals']))]]
        .reject { |_, list| list.empty? }
    end

    # このページが足した科目のうち、人が値を直したあとで確認を外したもの。確認済みでないので、読み直すと AI の読みに入れ替わる
    # (直した値を持つ印 read_fp が残っている)。気づかないまま直しが消えないよう、先に言う。
    def reverted_courses(document, contributed)
      keys = Array(contributed['courses'])
      lost = Array(document['courses']).grep(Hash).select do |course|
        keys.include?(course['key']) && course['confirmed'] != true && course[CourseEdit::READ_FP].present?
      end
      lost.map { |course| course_label(course) }
    end

    def course_label(course)
      [course['number'], course['name']].compact_blank.join(' ').presence || course['key'].to_s
    end

    # このページが足した科目のうち、人が確認した(直した)もの。名前は「番号 名前」。
    def course_names(document, contributed)
      keys = Array(contributed['courses'])
      confirmed = Array(document['courses']).grep(Hash).select do |course|
        keys.include?(course['key']) && course[DraftMerge::CONFIRMED] == true
      end
      confirmed.map { |course| course_label(course) }
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
      entries = Array(document[DraftMerge::REMOVED]).grep(Hash).select { |entry| entry['page'] == number }
      entries.map { |entry| [entry['kind'], removed_name(entry)] }
    end

    KIND_NAMES = { 'rule' => '規則', 'group' => '章', 'row' => '行', 'subtotal' => '小計', 'course' => '科目' }.freeze

    def removed_name(entry)
      return "承認の注記(区分「#{entry['category']}」)" if entry['kind'] == 'approval_note'

      "#{KIND_NAMES.fetch(entry['kind'], entry['kind'])}「#{entry['id']}」"
    end

    def text(number, kept, removed, reverted)
      lines = ["#{number}ページを読み直します。"]
      if kept.any?
        lines << '人が直した次の項目は、読み直した結果では上書きせず、そのまま残します(読み直した値が違えば、このページの警告に出ます)。' \
                 "#{kept.map { |noun, list| "#{noun}: #{summary(list)}" }.join(' / ')}。" \
                 '直した行を含む章は、直していない行も含めて、章ごと残ります。'
      end
      if reverted.any?
        lines << '人が値を直したあとで確認を外した次の科目は、読み直すと、直した値が AI の読みに入れ替わります' \
                 "(確認済みの科目だけが残ります): #{summary(reverted)}。"
      end
      lines.concat(removed_lines(removed))
      lines << 'このページが足した、それ以外の規則・章・行は、読み直した結果に入れ替わります。よろしいですか?'
      lines.join("\n")
    end

    # 規則・章・行などは、読み直しても戻らない。科目は、同じ読みの行を入れないが、読んだ内容が変わっていれば、警告つきで入る。
    def removed_lines(removed)
      courses, others = removed.partition { |kind, _| kind == DraftMerge::HumanCourses::COURSE }.map { |list| list.map(&:last) }
      lines = []
      lines << "人が消した次の項目は、読み直しても戻しません: #{summary(others)}。" if others.any?
      if courses.any?
        lines << '人が消した次の科目は、同じ読みの行を入れません。ただし、読み直した内容が変わっていれば、警告をつけて入ります' \
                 "(消した科目かどうか、ページの警告で確かめてください): #{summary(courses)}。"
      end
      lines
    end

    def summary(list)
      rest = list.size - SHOWN
      "#{list.first(SHOWN).join('・')}#{"ほか#{rest}件" if rest.positive?}"
    end
  end
end

