# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 文書の骨組みの検査。科目・規則・画面の表のどれかが丸ごと無い便覧は、個々の検査が見るものが無いので、
    # 他の検査はどれも黙って通ってしまう(空の便覧には、突き合わせる相手がいない)。
    #
    # 判定は、規則が無ければ何も確かめず、科目が無ければ学生の履修をすべて「科目表に無い科目」にする。どちらも
    # 要確認に倒れて充足とは言わないが、そのまま学生に出せる便覧ではない。人が直せる(ページを読む)ので、公開は止める。
    # 規則を持つのに display が無い便覧は、Catalogue は読み込めても画面が開けない(Catalogue は判定側の object で、
    # display は画面の元なので、読み込みの時には求めない)。学生に出せる状態かどうかは、ここで決める。
    class DocumentChecks < Checks
      def run
        no_courses
        findings.blocking(:rule, 'rules', '判定の規則が1つもありません。要件表のページを読み取るか、規則を足してください。') if input.rules.empty?
        missing_display
      end

      private

      # 科目0件は、読み落としで区分ごと消えた疑いがあるので止める。ただし、数える区分がすべて番号パターンを持つなら、
      # 科目を持たずに判定できるので止めない。数える区分が1つも無い便覧は、その根拠が無いので止める。
      def no_courses
        return unless input.courses.empty?
        return if input.counted_category_keys.any? && input.counted_category_keys.all? { |key| input.patterned?(key) }

        findings.blocking(:course, 'courses', '科目が1つもありません。科目表のページを読み取り、科目を足してください。')
      end

      def missing_display
        return if input.rules.empty? || input.document['display'].is_a?(Hash)

        findings.blocking(:display, 'display', '画面の要件表(display)がありません。規則はあっても、学生の画面に章と行が出せません。' \
                                               '要件表のページを読み取り直すか、章と行を足してください。')
      end
    end
  end
end

