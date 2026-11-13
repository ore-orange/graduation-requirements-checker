# frozen_string_literal: true

module CurriculumImport
  class RequirementsReview
    # 決まりが「持ち主(行・章・枠・総単位の枠)と同じことを言っているか」(設計書 項目1)。
    #
    # 2024年度の実データでは、27個の決まりのうち12個が、すぐ上の行・章・枠と文字どおり同じ
    # (同じ必要単位・同じ区分)。同じことを二度書いた箱は、PDFと突き合わせる手がかりを増やさず、
    # 画面を読めなくするだけなので出さない。
    #
    # この判定は1か所にしかない。画面(どの箱を出すか)と保存(どの決まりに書き戻すか)が同じものを引く。
    # 2か所で別々に決めると、画面が隠したのに保存が書かない穴ができ、人が行を直しても判定が動かなくなる。
    #
    # 迷ったら箱を出す。隠してよいのは、同じ値が持ち主にそのまま出ているときだけ
    # (アンチゴール「減らすのは人が打つ欄であって、人が見る値ではない」)。
    class Mirror
      # 隠してよい決まりの型。入れ子や関門を持つ型は、持ち主の「◯単位以上」では言い表せない。
      MIRRORED_TYPE = 'credit_sum'

      def initialize(input)
        @input = input
      end

      # rule を、その持ち主の欄が言い尽くしているか。
      # owner_kind は :row / :group / :frame / :total。owner は行・章の Hash、枠は Tree::Frame、総単位は nil。
      # blocked は、その決まりに突き合わせの指摘か入力の問題が付いていること。付いていれば必ず箱を出す
      # (隠すと、指摘を出す場所が画面から消え、上のまとめに規則の id だけが残る)。
      def duplicate?(rule, owner_kind, owner, blocked: false)
        return false if blocked
        return false unless rule.is_a?(Hash) && rule['type'] == MIRRORED_TYPE

        same_credits?(rule['required_credits'], required_credits(owner_kind, owner)) &&
          same_set?(rule['categories'], counted_categories(owner_kind, owner))
      end

      # 持ち主が数える区分。書き戻し(RequirementsEdit::MirrorWriteback)も、この同じ集合を書く。
      #   行   … その行の区分
      #   章・枠 … 中の行の区分の合併
      #   総単位 … 卒業の総単位に数える区分すべて
      def counted_categories(owner_kind, owner)
        case owner_kind
        when :row then categories_of(owner)
        when :group then merged_categories(rows_of_group(owner))
        when :frame then merged_categories(rows_of_frame(owner))
        when :total then @input.counted_category_keys
        else []
        end
      end

      private

      def required_credits(owner_kind, owner)
        return @input.display['total_credits'] if owner_kind == :total
        return owner.subtotal['required_credits'] if owner_kind == :frame

        owner.is_a?(Hash) ? owner['required_credits'] : nil
      end

      def merged_categories(rows) = rows.flat_map { |row| categories_of(row) }.uniq

      def rows_of_group(group)
        Array(group.is_a?(Hash) ? group['rows'] : nil).grep(Hash)
      end

      def rows_of_frame(frame)
        Array(frame.respond_to?(:rows) ? frame.rows : nil).grep(Hash)
      end

      def categories_of(row)
        Array(row.is_a?(Hash) ? row['categories'] : nil).grep(String)
      end

      # 2 と 2.0 は同じ単位。文字どおりで見ると、読み取りの書き方の違いで箱が出たり消えたりする。
      def same_credits?(left, right)
        left = GraduationAssessment::Ledger.decimal(left)
        right = GraduationAssessment::Ledger.decimal(right)
        !left.nil? && left == right
      end

      def same_set?(left, right)
        left = Array(left).grep(String)
        return false if left.empty?

        left.uniq.sort == Array(right).grep(String).uniq.sort
      end
    end
  end
end

