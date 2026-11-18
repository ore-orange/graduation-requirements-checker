# frozen_string_literal: true

class GraduationAssessment
  # 必要単位を持たない行が、どの枠(小計)・章の単位に数えられるのかを、便覧の display から見分ける。
  #
  # 便覧には「3区分で22単位」のような、複数の行をまとめた決まりの置き場所が無かった年度がある。2024年度の
  # 専門選択科目はその22を真ん中の行に押し込み、残りの行に「内数22単位枠」と書いて辻褄を合わせていた。
  # 数えられる先が display から分かるなら、画面はその枠・章の単位を出せるので、人が書いた説明文は要らない。
  #
  # 同じ見分け方を、読み込みの検査(Catalogue が required_label を求めるか)と画面のカード
  # (RequirementCardsHelper の「この枠の22単位に含む」)の両方で使う。2つが食い違うと、画面に出せない行を
  # 公開できてしまう(その行の必要単位が、どこにも出なくなる)。
  module DisplayCoverage
    class << self
      # この行をまとめている小計。単位を持つものだけを返す(0単位の小計は、何も要求していない)。
      def summing_subtotal(row, subtotals)
        return nil unless row.is_a?(Hash)

        Array(subtotals).grep(Hash).find do |subtotal|
          Array(subtotal['row_ids']).include?(row['id']) && credits?(subtotal)
        end
      end

      # 章が出している単位が、そのままこの行の要件か。章と同じ規則を指しているときだけ言える
      # (例: 章「専門選択 37単位」と行「専門科目(自由)」は、どちらも elective_total を指す)。
      # 章と違う規則を指す行は、その行の単位が消えていても章の数字では代えられない。
      def group_covers?(row, group)
        return false unless row.is_a?(Hash) && group.is_a?(Hash) && credits?(group)

        checks(row['check_ids']).intersect?(checks(group['check_id']))
      end

      def covered?(row, group, subtotals)
        !summing_subtotal(row, subtotals).nil? || group_covers?(row, group)
      end

      private

      def credits?(definition)
        value = definition['required_credits']
        value.is_a?(Numeric) && value.to_f.finite? && value.positive?
      end

      def checks(value) = Array(value).grep(String).compact_blank
    end
  end
end

