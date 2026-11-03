# frozen_string_literal: true

# 卒業要件の画面の「判定の規則」の節から、上のカードと同じことを言うだけの規則を省く。
# 規則の一文にする部分（RuleSentenceHelper）とは分けて、「どの規則を見せるか」だけを持つ。
module RuleTrimmingHelper
  # 判定の規則の節に出す規則。上のカードがすでに言っていることだけを繰り返す規則は省く。
  #
  # 省くのは「1つの区分だけを数える credit_sum」で、その区分だけを数える表示行（カード）が同じ単位数で出ているもの。
  # カードの「健康運動系 2単位」と規則の「健康運動系の合計 2単位以上」は、同じ内容の2回書きになる。
  # 次は、カードからは読み取れないので、必ず残す。
  #  - credit_sum 以外の型（系列の選択・選択経路・算入上限・算入しない・必修すべて・同一グループ）
  #  - 複数の区分を数える credit_sum（カードは区分ごとの数字しか出さず、まとめた要件を言えない）
  #  - 複数の区分をまとめた1枚のカードの中にある、1区分の下限（人文2・自然2 など。カードの数字は全体の12単位だけ）
  #  - カードと単位数が違う、1区分の credit_sum（カードは別の数字を言っている）
  #  - 解釈できない規則（赤で出す。間引いて見えなくしない）
  # どの規則を省くかは、規則 id の一覧ではなく、便覧の display と rules から決める（便覧が変わっても同じ考え方が通る）。
  def visible_rules(curriculum)
    credits_by_sole_category = sole_category_card_credits(curriculum)
    Array(curriculum['rules']).reject { |rule| repeats_card?(rule, credits_by_sole_category) }
  end

  # 規則の節で省いた件数。省いたことを画面で伝えるのに使う。
  def omitted_rule_count(curriculum) = Array(curriculum['rules']).size - visible_rules(curriculum).size

  private

  # 「その区分だけを数えるカード」が出している単位数。{ 区分キー => [単位数, ...] }。
  # 複数の区分をまとめたカードは入れない（その中の1区分の下限は、カードから読み取れないため）。
  def sole_category_card_credits(curriculum)
    sole_category_rows(curriculum).each_with_object({}) do |row, credits|
      (credits[row['categories'].first] ||= []) << row['required_credits']
    end
  end

  def sole_category_rows(curriculum)
    display = curriculum['display']
    groups = display.is_a?(Hash) ? Array(display['groups']) : []
    rows = groups.flat_map { |group| group.is_a?(Hash) ? Array(group['rows']) : [] }
    rows.select { |row| row.is_a?(Hash) && sole_category?(row) && row['required_credits'].is_a?(Numeric) }
  end

  # 1つの区分だけを持つか（行も規則も、区分は categories の配列で持つ）
  def sole_category?(definition) = definition['categories'].is_a?(Array) && definition['categories'].one?

  def repeats_card?(rule, credits_by_sole_category)
    return false unless rule.is_a?(Hash) && rule['type'] == 'credit_sum'
    return false unless sole_category?(rule) && rule['required_credits'].is_a?(Numeric)

    credits_by_sole_category.fetch(rule['categories'].first, []).include?(rule['required_credits'])
  end
end

