# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 知らない型、または置けない位置の規則。充足とは答えず、必ず要確認にして理由を残す。
    class Unknown < Base
      def outcome(_catalogue, _ledger)
        Outcome.new(satisfied: false, review: true, counted: nil)
      end

      def check(_catalogue, _ledger)
        build_check(status: :needs_review, counted: nil, required: nil, missing: [],
                    detail: "この規則は判定できません（種類: #{definition['type'].inspect}）。便覧の確認が必要です。")
      end
    end
  end
end

