# frozen_string_literal: true

# 公開済みの卒業要件を、親子が見えるカードで出すための組み立て。
#
# 便覧の display は「章 → 行」の2段しか持たず、複数の行をまとめる小計は別立ての配列に、判定の中身は rules に
# 分かれている。そのまま並べるとカードが平らになり、「教養・総合領域」の中の人文・社会・自然や、「外国語科目」の
# いずれかを満たす経路が、画面のどこにも形として出ない。ここでは次の4段を1本の木に組み立てる。
#
#   卒業に必要な単位 → 章(display.groups) → 枠(display.subtotals)・行(rows) → 決まり(rules)
module RequirementCardsHelper
  include RequirementRuleCardsHelper

  Frame = CurriculumImport::RequirementsReview::Tree::Frame
  # 1枚の便覧ぶんの引き当て。章・枠の組み立てと、id から決まりを引く表を1回だけ作る。
  Deck = Struct.new(:document, :tree, :subtotals, :rules_by_id, keyword_init: true)

  def requirement_deck(document)
    input = CurriculumImport::Validation::Input.new(document, [])
    Deck.new(document: document, tree: CurriculumImport::RequirementsReview::Tree.new(input),
             subtotals: input.subtotals, rules_by_id: input.rules.grep(Hash).index_by { |rule| rule['id'] })
  end

  def requirement_frame?(node) = node.is_a?(Frame)

  # 行のカードに渡す値。parent は、その行を囲む枠(無ければ nil)。
  # どの枠・章の単位に数えられるのかは、枠と章の囲いが示すので、行の中には文で書かない。
  def row_card_locals(deck, row, parent, group)
    { id_attr: { row: row['id'] }, name: row['name'], note: row['subtitle'], label: row['required_label'],
      credits: (row['required_credits'] if row_own_credits?(row, parent)),
      rules: rule_cards(deck, row, parent, group) }
  end

  # 行が自分の必要単位を数字で出すか。
  # 枠と同じ規則・同じ単位数を指しているだけの行は、枠に数字の置き場所が無かったせいでその数字を預かっている
  # (2024年度の「知能情報アドバンスト 22単位」がこれ)。枠と行で同じ22を2つ並べると22＋22に見えるので、
  # 数字は枠に任せ、行は「この枠の22単位に含む」とだけ言う。
  def row_own_credits?(row, parent)
    return false unless row['required_credits'].is_a?(Numeric)
    return true unless requirement_frame?(parent)

    !same_requirement_as_frame?(row, parent.subtotal)
  end

  private

  def same_requirement_as_frame?(row, subtotal)
    return false unless subtotal['required_credits'] == row['required_credits']

    checks = Array(row['check_ids']).grep(String).compact_blank
    checks.any? && (checks - Array(subtotal['check_ids']).grep(String)).empty?
  end
end

