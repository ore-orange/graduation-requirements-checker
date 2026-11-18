# frozen_string_literal: true

module CurriculumImport
  module ApprovalNotes
    # 承認の注記を外す処理。外した注記が、科目の関門にも、読み直しにも残らないようにする。
    module Removal
      module_function

      # 注記を外す。その注記で真にした科目(BY_NOTE の印があるもの)のうち、残った注記のどれにも当たらないものは、
      # 承認の関門を戻す。AI が行から読んだ真は、注記とは別の根拠なので、戻さない。戻した科目の key を返す。
      def retract(document, note)
        notes = Array(document[KEY])
        notes.delete(note)
        document.delete(KEY) if notes.empty?
        Array(document['courses']).filter_map do |course|
          next unless course[BY_NOTE] && ApprovalNotes.covers?(note, course) && notes.none? do |other|
            ApprovalNotes.covers?(other, course)
          end

          course['requires_approval'] = false
          course.delete(BY_NOTE)
          # もう一度見る印は、承認を付けたことへの印。承認を戻したら、役目を終える。
          course.delete(REVIEW_AGAIN)
          course['key']
        end
      end

      # 人が外した注記(document['removed_by_human'])に当たる注記を除く。読み直しが、外した注記を戻さないため。
      def without_removed(document, notes)
        removed = Array(document[DraftMerge::REMOVED]).grep(Hash).select { |entry| entry['kind'] == 'approval_note' }
        notes.reject do |note|
          removed.any? do |entry|
            [entry['page'], entry['scope'],
             entry['category']] == [page_number(note['source_page']), note['scope'], note['category']]
          end
        end
      end

      # 外したことを記録する。読み直しが、同じページの同じ区分の注記を戻さない(without_removed が見る)。
      def record(document, card_id, note)
        entry = { 'kind' => 'approval_note', 'id' => card_id, 'scope' => note['scope'], 'category' => note['category'],
                  'page' => page_number(note['source_page']) }
        (document[DraftMerge::REMOVED] ||= []) << entry.compact
      end

      # 'PDF11ページ' → 11。人が足した注記(出典が無い)は nil。
      def page_number(label)
        label.to_s[/\APDF(\d+)ページ\z/, 1]&.to_i
      end
    end
  end
end

