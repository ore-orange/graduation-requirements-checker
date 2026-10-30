# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # そのページが前に足したもの(contributed)を、document から外す。ページの種別を替えたときにも使う。
    # いまの種別ではなく、記録に何があるかで外す。種別を替えて読み直しても、前の種別の分を取り残さない。
    #
    # 人が見て直したもの(confirmed)は外さない。科目だけでなく、規則・章・行・小計も同じ。確認画面で直した値を、
    # 読み直しが黙って AI の読みに戻すと、「必要単位 37」を直した人が、また間違った数字で判定される(アンチゴールの形)。
    # 章は、章そのものか、その行のどれかが直されていれば、章ごと残す(行だけ抜くと、直した行が居場所を失う)。
    # 総単位は値そのものなので印を持てない。直したときに、確認画面がそのページの記録(total_credits)を外すことで守る。
    #
    # 戻り値は、残したものの記録({ 'courses' => key, 'rules' => id, 'groups' => id, 'subtotals' => id }。空の欄は無い)。
    # 呼び出し側は、これを次の記録に引き継ぐ。手放すと、読み直したときに同じものが二重に入る。
    module Withdrawal
      module_function

      def call(document, contributed, page)
        contributed ||= {}
        kept = requirements(document, contributed)
        ApprovalNotes.replace_page_notes(document, page, [])
        keys = Array(contributed['courses'])
        document['courses']&.reject! { |course| keys.include?(course['key']) && !course[CONFIRMED] }
        kept['courses'] = Array(document['courses']).select { |course| keys.include?(course['key']) }.pluck('key')
        kept.reject { |_, ids| ids.empty? }
      end

      def requirements(document, contributed)
        display = document['display'] || {}
        kept = { 'rules' => drop(document['rules'], contributed['rules']),
                 'groups' => drop(display['groups'], contributed['groups']),
                 'subtotals' => drop(display['subtotals'], contributed['subtotals']) }
        display.delete('total_credits') if contributed['total_credits']
        kept
      end

      # list から ids の項目を外す。人が直したものは残し、その id を返す。
      def drop(list, ids)
        kept = []
        list&.reject! do |item|
          next false unless Array(ids).include?(item['id'])
          next true unless human_edited?(item)

          kept << item['id']
          false
        end
        kept
      end

      # 章は、行のどれかが直されていれば直された章として扱う。
      def human_edited?(item)
        item[CONFIRMED] == true || Array(item['rows']).any? { |row| row.is_a?(Hash) && row[CONFIRMED] == true }
      end
    end
  end
end

