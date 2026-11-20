# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 取り込みのページの状態から拾う検査。document だけでは分からないこと(どのページが、どう読まれたか)を見る。
    #
    # 承認の注記(ApprovalNotes)の2つの警告は、どちらもページの抽出テキストを見る。テキスト層の無いスキャンPDFでは
    # テキストが空になり、両方とも黙って死ぬ。印刷された「承認」の注記があっても、誰にも知られず、その科目の単位は
    # 承認なしで数えられる。注記が1つも無いのに、読んだページにテキストが無いなら、見落とした可能性を人に渡す。
    class PageChecks < Checks
      MENTION = ApprovalNotes::MENTION

      def run
        textless_pages
        approval_warnings
        unread_pages
      end

      private

      def read_pages
        input.pages.select do |page|
          Curriculum::READABLE_PAGE_KINDS.include?(page['kind']) && page['status'] == 'read'
        end
      end

      def textless_pages
        return if input.approval_recorded?

        blank = read_pages.select { |page| page['text'].to_s.strip.empty? }
        return if blank.empty?

        findings.warning(:document, page_label(blank), '文字の層が無い(スキャンされた)ページがあり、承認の注記が1つもありません。' \
                                                       '承認の警告はページの文字から拾うので、このページでは働きません。印刷された「指導教員の承認」の注記を、' \
                                                       'ページ画像で確かめてください。')
      end

      # ページの読み取りが「承認」に触れる警告を残しているのに、注記も承認の印の付いた科目も無いまま。
      # 警告は読み取りの画面にもあるが、公開の前の確認で見落とさないよう、ここにも出す。
      def approval_warnings
        return if input.approval_recorded? || input.courses.any? { |course| course['requires_approval'] == true }

        warned = input.pages.select do |page|
          Array.wrap(page['warnings']).any? do |warning|
            warning.to_s.match?(MENTION)
          end
        end
        return if warned.empty?

        findings.warning(:document, page_label(warned), 'ページの文字に「承認」とあるのに、承認の注記も、承認が必要な科目もありません。' \
                                                        '承認が要る科目の単位は、承認なしで数えられます。')
      end

      # 読む種別なのに読めていないページの科目・規則は、文書に入っていない。単位が反映されない。
      def unread_pages
        unread = input.pages.select do |page|
          Curriculum::READABLE_PAGE_KINDS.include?(page['kind']) && page['status'] != 'read'
        end
        return if unread.empty?

        findings.warning(:document, page_label(unread), '読み取れていないページがあります。そのページの科目・規則は文書に入っていないので、単位が反映されません。')
      end

      def page_label(pages)
        "PDF#{pages.pluck('page').sort.join('・')}ページ"
      end
    end
  end
end

