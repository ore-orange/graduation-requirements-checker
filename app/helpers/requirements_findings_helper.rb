# frozen_string_literal: true

# 要件表の確認画面で、突き合わせの指摘(CurriculumImport::Validation)を人に見せる部品。
# 指摘の target は突き合わせ用の id。見せる文字は label で、画面の箱へ飛ぶ先は target から組み立てる。
module RequirementsFindingsHelper
  # 指摘から、画面の該当する箇所(規則の箱・行・章・小計)へ飛ぶ先。指摘の target は id のまま持っているので、そこから組み立てる。
  # 該当する箱が画面に無い指摘(文書全体・区分・科目など)は nil。リンクを出して、押しても何も起きない、を作らない。
  # 規則の指摘が付いた決まりは、箱を必ず出す(RequirementsReview#hidden_rule)ので、#rule-<id> はある。
  def finding_anchor(finding, review)
    target = finding[:target]
    case finding[:scope]
    when :rule then "#rule-#{target}" if review.rule_ids.include?(target)
    when :display then display_anchor(target, review)
    end
  end

  # 行・章・小計のうち、その id を持つものが1つだけのときに限る(種類を決められないなら出さない)。
  def display_anchor(target, review)
    items = { 'row' => review.groups.flat_map { |group| review.rows_of(group) }, 'group' => review.groups,
              'subtotal' => review.subtotals }
    kinds = items.select { |_, list| list.any? { |item| item['id'] == target } }.keys
    "##{kinds.first}-#{target}" if kinds.one?
  end

  # 規則の名前(label が無ければ、持ち主の行と型の和名)。id が見つからなければ、id は出さず「足した決まり」と言う。
  def rule_name_for(id, review)
    rule = review.rules.find { |candidate| candidate['id'] == id }
    rule ? review.rule_name(rule) : '足した決まり'
  end
end

