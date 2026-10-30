# frozen_string_literal: true

module CurriculumImport
  # 「指導教員の承認が要る」という便覧の注記を、ページを跨いで科目の requires_approval に反映する。
  #
  # requires_approval は科目表を1ページずつ読むときに、そのページの中の手掛かりだけで決まる。
  # 承認の注記が科目の行と別のページ(要件表の注や、区分の見出し)にあると、その科目は false になる。
  # false は寛容側で、判定は真のときだけ承認の関門を足すので、見落とした注記はそのまま単位の水増しになる。
  # そこで注記を document['approval_notes'] に残し、ページを読むたびに(読む順番に関わらず)科目へ当て直す。
  #
  # 注記の形は2つ。
  #   区分: { 'scope' => 'category', 'category' => 区分の key, 'text' => 注記の文, 'source_page' => 読んだページ }
  #   ページ: { 'scope' => 'page', 'page' => ページ番号, 'text' => 注記の文 }  そのページから読んだ科目すべて
  # 注記の数え方は、読み取りの答えには欄が無いので、要件表の規則・表示の行の文に「承認」とあるものから拾う。
  # 対象の区分が分からない注記は、当てずに警告として残す(人が見る)。当て推量で関門を足さない。
  module ApprovalNotes
    KEY = 'approval_notes'
    MENTION = /承認/
    RULE_TEXT_FIELDS = %w[label detail review_note reason].freeze
    ROW_TEXT_FIELDS = %w[name subtitle required_label].freeze
    NESTED = %w[options conditions].freeze
    EXCERPT_LENGTH = 60
    # ページの警告に残す文。確認画面は、これらを「科目に当てられなかった承認の注記」のカードにする(警告が唯一の記録)。
    UNRESOLVED_PREFIX = '承認の注記らしい文がありますが、対象の区分が分からず科目に反映していません: '
    UNWRITTEN_WARNING = 'このページの文字に「承認」とありますが、規則にも表示の行にも書き取られていません。' \
                        '承認が要る科目の区分を確かめ、必要なら承認の注記を足してください。'

    class << self
      # 注記に当たる科目を真にする(document を直接書き換える)。戻り値は、新しく真にした科目の key。
      # 偽には戻さない(戻す側の誤りは水増しになる)。確認済みだった科目は、承認の有無が変わったので確認を外して見直しに戻す。
      def apply(document)
        notes = Array(document[KEY])
        return [] if notes.empty?

        Array(document['courses']).filter_map do |course|
          next if course['requires_approval'] == true
          next unless notes.any? { |note| covers?(note, course) }

          course['requires_approval'] = true
          course['confirmed'] = false if course['confirmed']
          course['key']
        end
      end

      # 注記を足して、いまある科目に当てる。人が画面から足す入口でもある。
      def add(curriculum, note)
        curriculum.with_lock do
          document = curriculum.document.deep_dup
          notes = (document[KEY] ||= [])
          notes << note.stringify_keys unless notes.include?(note.stringify_keys)
          apply(document)
          curriculum.update!(document: document)
        end
      end

      # 1つの要件表のページから拾える注記と、対象が分からず当てられなかった注記の文。
      # [区分の注記の配列, 当てられなかった文の配列]
      def detect(answer, page)
        label = DraftMerge.source_page_label(page)
        mentions = rule_mentions(Array(answer['rules'])) + row_mentions(answer.dig('display', 'groups'))
        notes = mentions.select { |mention| mention[:categories].any? }.flat_map do |mention|
          mention[:categories].map do |category|
            { 'scope' => 'category', 'category' => category, 'text' => mention[:text], 'source_page' => label }
          end
        end
        [notes.uniq { |note| note['category'] }, mentions.select do |mention|
          mention[:categories].empty?
        end.pluck(:text).uniq]
      end

      # そのページが前回の読み取りで足した注記を外して、今回の分に入れ替える。人が足した注記(source_page なし)は残す。
      # 注記はページごとに持つ。同じ区分の注記が別のページにもあるとき、片方を捨てると、残した側のページを
      # 読み直して文言が消えた時に、注記が誰にも残らない。重なりは apply が見るだけなので害がない。
      def replace_page_notes(document, page, notes)
        label = DraftMerge.source_page_label(page)
        merged = Array(document[KEY]).reject { |note| note['source_page'] == label } + notes
        merged.empty? ? document.delete(KEY) : document[KEY] = merged
      end

      # 要件表のページの文字に「承認」とあるのに、そこから注記を拾えなかったとき(規則にも行にも書かれなかった)の警告。
      # 要件表の注は、別のページの科目の承認を決める。見落とすと関門が付かず、単位が無条件に数えられる。
      def requirements_page_warning(text, found)
        return if found || !text.to_s.match?(MENTION)

        UNWRITTEN_WARNING
      end

      def unresolved_warning(text)
        "#{UNRESOLVED_PREFIX}#{text}"
      end

      # 科目表のページの文字に「承認」とあるのに、そのページのどの科目にも承認の印が付いていないとき、確認を促す文。
      # モデルにも注記の別ページ参照にも手掛かりが無い唯一の場合を、機械で拾える範囲で人に知らせる。
      def course_page_warning(document, page, text)
        return unless text.to_s.match?(MENTION)

        label = DraftMerge.source_page_label(page)
        on_page = Array(document['courses']).select { |course| course['source_page'] == label }
        return if on_page.empty? || on_page.any? { |course| course['requires_approval'] == true }

        'このページの文字に「承認」とありますが、承認が要る科目として読めた科目がありません。' \
          '科目の「承認が必要」を確かめてください。'
      end

      private

      def covers?(note, course)
        case note['scope']
        when 'category' then course['category'] == note['category']
        when 'page' then course['source_page'] == DraftMerge.source_page_label(note['page'])
        else false
        end
      end

      def rule_mentions(rules)
        rules.flat_map do |rule|
          children = NESTED.flat_map { |field| rule_mentions(Array(rule[field])) }
          text = mentioned_text(rule, RULE_TEXT_FIELDS)
          own = text ? [{ text: text, categories: rule_categories(rule) }] : []
          own + children.map do |child|
            child[:categories].empty? ? child.merge(categories: rule_categories(rule)) : child
          end
        end
      end

      # 規則が名指しする区分。入れ子の規則は、親の区分も継ぐ。
      def rule_categories(rule)
        direct = Array(rule['category']) + Array(rule['categories']) + Array(rule['required_categories'])
        (direct + NESTED.flat_map { |field| Array(rule[field]).flat_map { |child| rule_categories(child) } }).uniq
      end

      def row_mentions(groups)
        Array(groups).flat_map { |group| Array(group['rows']) }.filter_map do |row|
          text = mentioned_text(row, ROW_TEXT_FIELDS)
          { text: text, categories: Array(row['categories']) } if text
        end
      end

      def mentioned_text(hash, fields)
        text = fields.filter_map { |field| hash[field] }.find { |value| value.to_s.match?(MENTION) }
        text.to_s.strip.first(EXCERPT_LENGTH) if text
      end
    end
  end
end

