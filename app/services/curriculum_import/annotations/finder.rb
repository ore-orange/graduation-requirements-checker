# frozen_string_literal: true

module CurriculumImport
  module Annotations
    # document とページの警告から、注釈のカードを見つける。承認の注記を先に、外国人学生の特例をあとに並べる。
    # カードの id は種類・ページ・文から決める。読み直しで元が作り直されても、同じ注釈なら同じ id に戻る。
    module Finder
      module_function

      def call(document, pages)
        pages = Array(pages).grep(Hash)
        applied_notes(document) + unattached_notes(pages) + foreign_students(document, pages)
      end

      def digest(kind, *parts)
        Digest::SHA256.hexdigest([kind, *parts].join('|')).first(10)
      end

      # 科目に反映済みの承認の注記(document['approval_notes'])。
      def applied_notes(document)
        notes = document.is_a?(Hash) ? Array(document[ApprovalNotes::KEY]).grep(Hash) : []
        notes.map do |note|
          text = note['text'].to_s
          where = note['category'] || note['page']
          Card.new(id: digest(:approval_applied, note['scope'], where, text), kind: :approval_applied, text: text,
                   page: note['source_page'] || note['page'], covers: covered_courses(document, note))
        end
      end

      def covered_courses(document, note)
        courses = Array(document['courses']).grep(Hash)
        case note['scope']
        when 'category' then courses.count { |course| course['category'] == note['category'] }
        when 'page' then courses.count { |course| course['source_page'] == DraftMerge.source_page_label(note['page']) }
        else 0
        end
      end

      # ページの警告が、承認の注記を科目に当てられなかった唯一の記録。警告の文からカードに戻す。
      def unattached_notes(pages)
        pages.flat_map do |page|
          Array(page['warnings']).filter_map { |warning| unattached_card(page, warning.to_s) }
        end
      end

      def unattached_card(page, warning)
        text = if warning.start_with?(ApprovalNotes::UNRESOLVED_PREFIX)
                 warning.delete_prefix(ApprovalNotes::UNRESOLVED_PREFIX)
               elsif warning == ApprovalNotes::UNWRITTEN_WARNING
                 excerpts(page['text'].to_s, ApprovalNotes::MENTION).first || '(ページの文字に「承認」とあります)'
               end
        return unless text

        Card.new(id: digest(:approval_unattached, page['page'], text), kind: :approval_unattached, text: text,
                 page: page['page'])
      end

      # 規則・表示の行の文と、要件表のページの文字から、外国人学生の特例らしい文を拾う。
      def foreign_students(document, pages)
        from_document = document_texts(document).filter_map do |text|
          foreign_card(text, nil) if text.match?(FOREIGN_STUDENT)
        end
        from_pages = pages.select { |page| page['kind'] == 'requirements' }.flat_map { |page| page_mentions(page) }
        from_document + from_pages
      end

      def page_mentions(page)
        found = excerpts(page['text'].to_s, FOREIGN_STUDENT).first(MAX_PER_PAGE)
        found.map { |text| foreign_card(text, page['page']) }
      end

      def foreign_card(text, page)
        Card.new(id: digest(:foreign_student, page, text), kind: :foreign_student, text: text, page: page)
      end

      def document_texts(document)
        return [] unless document.is_a?(Hash)

        rules = Array(document['rules']).grep(Hash).flat_map { |rule| rule.values_at(*ApprovalNotes::RULE_TEXT_FIELDS) }
        groups = Array(document.dig('display', 'groups')).grep(Hash) if document['display'].is_a?(Hash)
        rows = Array(groups).flat_map { |group| Array(group['rows']).grep(Hash) }
        (rules + rows.flat_map { |row| row.values_at(*ApprovalNotes::ROW_TEXT_FIELDS) }).grep(String).map(&:strip).uniq
      end

      # 文字列のなかの、パターンに当たる箇所の前後。近いものは1つにまとめる。
      def excerpts(text, pattern)
        last_end = -1
        text.to_enum(:scan, pattern).map { Regexp.last_match }.filter_map do |match|
          next if match.begin(0) < last_end

          last_end = match.end(0) + CONTEXT
          text[[match.begin(0) - CONTEXT, 0].max...last_end].gsub(/\s+/, ' ').strip
        end
      end
    end
  end
end

