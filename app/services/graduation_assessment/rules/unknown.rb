# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 解釈できない規則。充足と答えず、必ず要確認にする。
    # 未対応の type と、置けない位置（入れ子の上限超えなど）にある規則がここに来る。
    # 便覧のデータを直す人に読まれるので、2つの理由を文面で分ける。
    class Unknown < Base
      def id
        definition['id'] || '（id なし）'
      end

      def label
        definition['label'] || id
      end

      def evaluate(_catalogue, ledger)
        ledger.notes << "#{id}：#{reason}"
        Outcome.new(satisfied: false, review: true, counted: Catalogue::ZERO, missing: [])
      end

      private

      def detail(_catalogue, _outcome, _status)
        "#{reason}ため、確認が必要です。"
      end

      # 型は正しいが置けない位置にある場合と、型そのものを知らない場合。
      def reason
        type = definition['type']
        if TYPES.key?(type)
          "規則の型「#{type}」はこの位置には置けません"
        else
          "規則の型「#{type}」をこのアプリは解釈できません"
        end
      end
    end
  end
end

