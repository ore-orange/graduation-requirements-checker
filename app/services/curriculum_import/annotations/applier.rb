# frozen_string_literal: true

module CurriculumImport
  module Annotations
    # カードの扱いを document に書く処理。取り消せない副作用(承認の注記・足した規則)を伴うものは、ここに集める。
    module Applier
      module_function

      # 決めた内容が、いまも効いているか。承認の注記・足した規則が消えていれば、決めた扱いは宙に浮いている(もう一度決められる)。
      # 「判定に反映しない」は何も足していないので、いつでも決め直せる。
      def settled?(document, decision)
        return false if decision.blank? || decision['disposition'] == IGNORE
        return note_stands?(document, decision) if decision['disposition'] == APPROVAL

        Array(document['rules']).grep(Hash).any? { |rule| rule['id'] == decision['rule_id'] }
      end

      def note_stands?(document, decision)
        text = decision['text'].to_s.first(ApprovalNotes::EXCERPT_LENGTH)
        Array(document[ApprovalNotes::KEY]).grep(Hash).any? do |note|
          note['scope'] == 'category' && note['category'] == decision['category'] && note['text'] == text
        end
      end

      def call(document, card, disposition, category)
        error = conflict(card)
        return error if error

        case disposition
        when IGNORE then record(document, card, IGNORE)
        when APPROVAL then approve(document, card, category)
        else add_rule(document, card, disposition)
        end
      end

      # 決めたあとに変えると、副作用が取り消せないもの(承認の注記・足した規則)がある。取り消せない変更は断る。
      # 「判定に反映しない」は何も足していないので、あとから別の扱いに変えられる。
      def conflict(card)
        decision = card.decision
        return if decision.blank? || !card.settled || decision['disposition'] == IGNORE

        if decision['disposition'] == APPROVAL
          return "すでに区分「#{decision['category']}」の承認の注記にしてあります。承認の注記は、注記の一覧から外してください。"
        end

        "すでに規則「#{decision['rule_id']}」を作ってあります。下の規則の表で直すか、消してください。"
      end

      # 注記から決めた承認の扱いを白紙に戻す(注記を外したので、もう一度決められる)。
      def forget_decisions(document, note)
        return unless document[KEY].is_a?(Hash)

        document[KEY].reject! do |_, decision|
          decision['disposition'] == APPROVAL && decision['category'] == note['category'] &&
            decision['text'].to_s.first(ApprovalNotes::EXCERPT_LENGTH) == note['text']
        end
        document.delete(KEY) if document[KEY].empty?
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

        id = Annotations.rule_id(card.id)
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

