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
    Card = Struct.new(:id, :kind, :text, :page, :decision, :covers, keyword_init: true) do
      # 反映済みの承認の注記は、もう判定に効いている。ここでは選ばせない。
      def decidable? = kind != :approval_applied

      def approval? = kind == :approval_unattached
    end

    class << self
      # 画面に出すカード。承認の注記を先に、外国人学生の特例をあとに並べる。
      def cards(document, pages)
        decisions = document.is_a?(Hash) && document[KEY].is_a?(Hash) ? document[KEY] : {}
        Finder.call(document, pages).uniq(&:id).map { |card| card.tap { |entry| entry.decision = decisions[entry.id] } }
      end

      # カード1つの扱いを決めて、document に書く。エラーのときは文言を返す(document は変えない)。
      def decide(document, pages, card_id, disposition, category: nil)
        card = cards(document, pages).find { |entry| entry.id == card_id }
        return 'この注釈は見つかりません。読み直しで変わった可能性があります。画面を開き直してください。' unless card&.decidable?

        error = conflict(document, card, disposition)
        return error if error

        case disposition
        when IGNORE then record(document, card, IGNORE)
        when APPROVAL then approve(document, card, category)
        else add_rule(document, card, disposition)
        end
      end

      def rule_id(card_id) = "annotation_#{card_id}"

      private

      # 決めたあとに変えると、副作用が取り消せないもの(承認の注記・足した規則)がある。取り消せない変更は断る。
      # 「判定に反映しない」は何も足していないので、あとから別の扱いに変えられる。
      def conflict(document, card, _disposition)
        decision = card.decision
        return if decision.blank? || decision['disposition'] == IGNORE

        return "すでに区分「#{decision['category']}」の承認の注記にしてあります。承認の注記は、ここからは外せません。" if decision['disposition'] == APPROVAL

        exists = Array(document['rules']).grep(Hash).any? { |rule| rule['id'] == decision['rule_id'] }
        "すでに規則「#{decision['rule_id']}」を作ってあります。下の規則の表で直すか、消してください。" if exists
      end

      def record(document, card, disposition, **extra)
        (document[KEY] ||= {})[card.id] = { 'disposition' => disposition, 'kind' => card.kind.to_s, 'text' => card.text,
                                            'page' => card.page }.merge(extra.stringify_keys)
        nil
      end

      def approve(document, card, category)
        return '承認の注記にできるのは、承認の注記のカードだけです。' unless card.approval?

        keys = Array(document['categories']).grep(Hash).pluck('key')
        return '承認の注記にする区分を選んでください。' unless keys.include?(category)

        # 人が足した注記は source_page を持たない。読み直しで、そのページの注記を入れ替えるときに消えない。
        note = { 'scope' => 'category', 'category' => category, 'text' => card.text.first(ApprovalNotes::EXCERPT_LENGTH) }
        notes = (document[ApprovalNotes::KEY] ||= [])
        notes << note unless notes.include?(note)
        ApprovalNotes.apply(document)
        record(document, card, APPROVAL, category: category)
      end

      def add_rule(document, card, type)
        return "規則の型を選んでください(#{RULE_TYPES.join('・')})。" unless RULE_TYPES.include?(type)

        id = rule_id(card.id)
        return "規則「#{id}」はすでにあります。" if Array(document['rules']).grep(Hash).any? { |rule| rule['id'] == id }

        (document['rules'] ||= []) << skeleton(card, type, id)
        record(document, card, type, rule_id: id)
      end

      # 型が要る欄を、空のまま持つ規則。空の欄は突き合わせが止めるので、数字を入れ忘れたまま公開されない。
      # confirmed は、人が足した規則を読み直しで消さないための印。
      def skeleton(card, type, id)
        rule = { 'id' => id, 'type' => type, 'detail' => card.text, DraftMerge::CONFIRMED => true }
        rule['label'] = card.text.first(40) unless GraduationAssessment::Rules::ADJUSTMENTS.key?(type)
        rule['source_page'] = DraftMerge.source_page_label(card.page) if card.page.is_a?(Integer)
        rule.merge(Validation::Input::FIELD_KINDS.fetch(type).transform_values do |kind|
          %i[keys paths list].include?(kind) ? [] : nil
        end)
      end
    end
  end
end

