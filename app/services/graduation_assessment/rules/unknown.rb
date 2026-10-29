# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 解釈できない規則。充足と答えず、必ず要確認にする。
    # 未対応の type と、入れ子の上限を超えた規則がここに来る。
    class Unknown < Base
      def id
        definition['id'] || '（id なし）'
      end

      def label
        definition['label'] || id
      end

      def evaluate(_catalogue, ledger)
        ledger.notes << "#{id}：規則の型「#{definition['type']}」をこのアプリは解釈できません"
        Outcome.new(satisfied: false, review: true, counted: Catalogue::ZERO, missing: [])
      end

      private

      def detail(_catalogue, _outcome, _status)
        "規則の型「#{definition['type']}」をこのアプリは解釈できないため、確認が必要です。"
      end
    end
  end
end

