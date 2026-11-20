# frozen_string_literal: true

module CurriculumImport
  # 便覧の注釈(表に収まらない但し書き)を、確認画面のカードにする。
  #
  # 注釈は機械で判定に落とせるとは限らない。落とせないものを、画面から消さずに、人の目に残すのがこのカード。
  # 人はカードごとに、どう扱うかを選ぶ。
  #  - 判定に反映しない: 記録だけして、判定は変えない。「見たうえで落とした」ことが残る。
  #  - 承認の注記にする(承認の注記のカードだけ): 区分を選ぶと、その区分の科目に指導教員の承認の関門が付く。
  #  - 規則の型(7つ)のどれか: その型の、中身が空の規則を足す。必要な値が空のあいだは、突き合わせが公開を止める
  #    (注釈を規則にすると決めたのに、数字を入れ忘れたまま公開されないように)。経路や選択肢が空の型
  #    (one_of_paths・any_of)は、判定が必ず「要確認」になる(充足とは言わない)ので、止めずに警告が出る。
  #
  # カードの元になるもの(document と、ページの警告)は、読み直しで作り直されることがある。カードの id は
  # 種類・ページ・文から決めるので、同じ注釈なら読み直しても同じカードに戻り、決めた内容が残る。
  # 決めた内容は document['annotation_decisions'] に持つ(読み直しは触れない)。
  module Annotations
    KEY = 'annotation_decisions'
    IGNORE = 'ignore'
    APPROVAL = 'approval'
    # 注釈から足せる規則の型。単独の規則として置ける型すべて(判定を作る5つと、算入を変える cap・exclude)。
    RULE_TYPES = Validation::Input::TOP_LEVEL
    # 外国人学生の特例は、判定の対象外と決めている(README)。便覧の文にこの語があれば、人の目に出す。
    FOREIGN_STUDENT = /外国人|留学生/
    CONTEXT = 30
    MAX_PER_PAGE = 5

    # kind は :approval_applied(科目に反映済みの承認の注記)・:approval_unattached(対象の区分が分からない承認の注記)・
    # :foreign_student。decision は人が決めた内容(無ければ nil)。covers は承認の注記が当たる科目の数。
    # settled は、決めた内容がいまも効いているか(足した規則・承認の注記が残っているか)。消えていれば、もう一度決められる。
    Card = Struct.new(:id, :kind, :text, :page, :decision, :covers, :settled, keyword_init: true) do
      # 反映済みの承認の注記は、もう判定に効いている。ここでは選ばせない。
      def decidable? = kind != :approval_applied

      def approval? = kind == :approval_unattached
    end

    class << self
      # 画面に出すカード。承認の注記を先に、外国人学生の特例をあとに並べる。
      def cards(document, pages)
        decisions = document.is_a?(Hash) && document[KEY].is_a?(Hash) ? document[KEY] : {}
        Finder.call(document, pages).uniq(&:id).map do |card|
          card.tap do |entry|
            entry.decision = decisions[entry.id]
            entry.settled = settled?(document, entry.decision)
          end
        end
      end

      # 承認の注記を外す。注記で真にした科目の関門を戻し、その注記から決めた扱いを白紙に戻し、外したことを記録する
      # (読み直しが、同じページの同じ注記を戻さない)。エラーのときは文言を返す。
      def remove_note(document, card_id)
        note = Array(document[ApprovalNotes::KEY]).grep(Hash).find { |entry| Finder.applied_id(entry) == card_id }
        return 'この承認の注記は見つかりません。画面を開き直してください。' unless note

        ApprovalNotes::Removal.retract(document, note)
        Applier.forget_decisions(document, note)
        ApprovalNotes::Removal.record(document, card_id, note)
        nil
      end

      # カード1つの扱いを決めて、document に書く。エラーのときは文言を返す(document は変えない)。
      def decide(document, pages, card_id, disposition, category: nil)
        card = cards(document, pages).find { |entry| entry.id == card_id }
        return 'この注釈は見つかりません。読み直しで変わった可能性があります。画面を開き直してください。' unless card&.decidable?

        Applier.call(document, card, disposition, category)
      end

      def rule_id(card_id) = "annotation_#{card_id}"

      delegate :settled?, to: Applier
    end
  end
end

