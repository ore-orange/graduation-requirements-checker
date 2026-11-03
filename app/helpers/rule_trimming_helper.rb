# frozen_string_literal: true

# 卒業要件の画面の「判定の規則」の節から、上のカードと同じことを言うだけの規則を省く。
# 規則の一文にする部分（RuleSentenceHelper）とは分けて、「どの規則を見せるか」だけを持つ。
module RuleTrimmingHelper
  # 判定の規則の節に出す規則。上のカードがすでに言っていることだけを繰り返す規則は省く。
  #
  # 省くのは credit_sum だけで、次のどちらかに当てはまるもの。
  #  1. 表示の要素（章・行・小計）が、その規則を check_id / check_ids で名指ししていて、その要素が出している必要単位が
  #     規則の必要単位と同じ。便覧自身が「この要素は、この規則の見せ方」と書いているので、推測は要らない。
  #     例：章「共通教育 30単位」は common_total を指す。章の見出しと規則が同じことを2回言う。
  #  2. 1つの区分だけを数える規則で、その区分だけを数える行（カード）が同じ単位数で出ている。
  #     check_ids を持たない便覧でも、「健康運動系 2単位」と「健康運動系の合計 2単位以上」の2回書きを省くため。
  # 次は、カードからは読み取れないので、必ず残す。
  #  - credit_sum 以外の型（系列の選択・選択経路・算入上限・算入しない・同一グループ・必修すべて）。
  #    必修すべては、章の見出しが57単位でも、「31科目すべて修得・余剰単位での代用は不可」まで言えるのは規則だけ。
  #  - どの要素にも名指しされない credit_sum（卒業算入総単位など。備考の算入上限は、上のカードにない）
  #  - 名指しされていても、要素の単位数が違う規則（人文系2単位は、14単位の行が名指す。行は14と言っているので、2は読み取れない）
  #  - 複数の区分をまとめた1枚のカードの中にある、1区分の下限（人文2・自然2 など）
  #  - 解釈できない規則（赤で出す。間引いて見えなくしない）
  # どの規則を省くかは、規則 id の一覧ではなく、便覧の display と rules から決める（便覧が変わっても同じ考え方が通る）。
  def visible_rules(curriculum)
    shown = card_statements(curriculum)
    Array(curriculum['rules']).reject { |rule| repeats_card?(rule, shown) }
  end

  # 規則の節で省いた件数。省いたことを画面で伝えるのに使う。
  def omitted_rule_count(curriculum) = Array(curriculum['rules']).size - visible_rules(curriculum).size

  private

  # 上のカードが言っていること。名指しした規則の id ごとの単位数と、その区分だけを数える行ごとの単位数。
  def card_statements(curriculum)
    elements = display_elements(curriculum)
    { referenced: referenced_credits(elements), sole_category: sole_category_credits(elements) }
  end

  # 章・行・小計。どれも required_credits を持ち、規則を check_id（章）か check_ids（行・小計）で名指しする。
  def display_elements(curriculum)
    display = curriculum['display']
    return [] unless display.is_a?(Hash)

    groups = Array(display['groups']).grep(Hash)
    (groups + groups.flat_map { |group| Array(group['rows']).grep(Hash) } + Array(display['subtotals']).grep(Hash))
  end

  # { 規則の id => [名指しした要素が出している単位数, ...] }
  def referenced_credits(elements)
    elements.each_with_object({}) do |element, credits|
      next unless element['required_credits'].is_a?(Numeric)

      (Array(element['check_ids']) + Array(element['check_id'])).each do |id|
        (credits[id] ||= []) << element['required_credits']
      end
    end
  end

  # { 区分キー => [その区分だけを数える行が出している単位数, ...] }。
  # 複数の区分をまとめた行は入れない（その中の1区分の下限は、カードから読み取れないため）。
  def sole_category_credits(elements)
    elements.each_with_object({}) do |element, credits|
      next unless sole_category?(element) && element['required_credits'].is_a?(Numeric)

      (credits[element['categories'].first] ||= []) << element['required_credits']
    end
  end

  # 1つの区分だけを持つか（行も規則も、区分は categories の配列で持つ）
  def sole_category?(definition) = definition['categories'].is_a?(Array) && definition['categories'].one?

  def repeats_card?(rule, shown)
    return false unless rule.is_a?(Hash) && rule['type'] == 'credit_sum' && rule['required_credits'].is_a?(Numeric)

    credits = rule['required_credits']
    return true if shown[:referenced].fetch(rule['id'], []).include?(credits)

    sole_category?(rule) && shown[:sole_category].fetch(rule['categories'].first, []).include?(credits)
  end
end

