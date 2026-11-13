# frozen_string_literal: true

# 行の下に出す「決まり」のカード。公開済みの卒業要件の画面で、行の数字の内訳（人文系2単位・社会系2単位…）や、
# いずれかを満たす選択経路を、行の中に入れ子で見せるための組み立て。
#
# 便覧の rules は display とは別の配列にあり、行からは check_ids で指されているだけなので、そのままでは
# 「教養・総合領域14単位」の中に何があるのか、「外国語科目12単位」をどう満たせるのかが画面に出ない。
module RequirementRuleCardsHelper
  include RuleSentenceHelper

  # 決まり1つ。children を持つ決まり(いずれか・すべて・系列)は入れ物なので、数字は子のカードが出す。
  RuleCard = Struct.new(:id, :name, :credits, :limit, :note, :badge, :children, keyword_init: true) do
    def container? = children.present?
  end

  BADGES = { 'any_of' => 'いずれかを満たす', 'all_of' => 'すべて満たす', 'paths' => 'いずれかの系列' }.freeze

  # 行の下に出す決まりのカード。行・枠・章がすでに数字で言っている合計は出さない(同じ数字を2度言わない)。
  def rule_cards(deck, row, parent, group)
    carded_rules(deck, row, parent, group).map { |rule| rule_card(rule, deck.document) }
  end

  # 行のカードに出した決まりの id。「判定の規則」の一覧から省く(カードがすでに言っている)。
  # 解釈できない部分を含む規則だけは省かない。判定で要確認になることを赤で知らせるのは一覧だけなので、
  # 省くとその警告ごと消えてしまう。
  def card_rule_ids(deck)
    all_carded_rules(deck).reject { |rule| rule_unknown?(rule, deck.document) }.filter_map { |rule| rule['id'] }
  end

  private

  def all_carded_rules(deck)
    Array(deck.document.dig('display', 'groups')).grep(Hash).each_with_index.flat_map do |group, index|
      deck.tree.nodes_of(index).flat_map do |node, _|
        rows = requirement_frame?(node) ? node.rows : [node]
        rows.flat_map { |row| carded_rules(deck, row, (node if requirement_frame?(node)), group) }
      end
    end
  end

  def carded_rules(deck, row, parent, group)
    ancestors = ancestor_check_ids(parent, group)
    rules = Array(row['check_ids']).grep(String).filter_map { |id| deck.rules_by_id[id] }
                                   .reject { |rule| restates_credits?(rule, row, ancestors) }
    rules + deck.tree.caps_of(row)
  end

  def rule_unknown?(rule, curriculum)
    rule_node(rule, curriculum, TOP_LEVEL_RULES).contains_unknown?
  end

  def ancestor_check_ids(parent, group)
    frame = requirement_frame?(parent) ? Array(parent.subtotal['check_ids']) : []
    (frame + Array(group['check_id'])).grep(String)
  end

  # 合計の決まりのうち、行・枠・章がもう数字で言っているもの。選択経路・指定科目・上限などは、
  # 数字だけでは言えないことを言うので省かない。
  def restates_credits?(rule, row, ancestor_ids)
    return false unless rule['type'] == 'credit_sum'
    return true if ancestor_ids.include?(rule['id'])

    row['required_credits'].is_a?(Numeric) && rule['required_credits'] == row['required_credits']
  end

  def rule_card(rule, curriculum)
    case rule['type']
    when 'any_of' then nested_card(rule, curriculum, 'options', GraduationAssessment::Rules::ANY_OF_OPTIONS)
    when 'all_of' then nested_card(rule, curriculum, 'conditions', GraduationAssessment::Rules::ALL_OF_CONDITIONS)
    when 'one_of_paths' then paths_card(rule, curriculum)
    when 'cap' then cap_card(rule, curriculum)
    else plain_card(rule, curriculum)
    end
  end

  def plain_card(rule, curriculum)
    RuleCard.new(id: rule['id'], name: rule_card_name(rule, curriculum),
                 credits: (rule['required_credits'] if rule['required_credits'].is_a?(Numeric)),
                 note: notes_of(rule, extra_note(rule, curriculum)))
  end

  def nested_card(rule, curriculum, field, allowed)
    children = Array(rule[field]).grep(Hash).map do |child|
      allowed.include?(child['type']) ? rule_card(child, curriculum) : unknown_card(child)
    end
    RuleCard.new(id: rule['id'], name: rule['label'].presence, badge: BADGES.fetch(rule['type']),
                 note: notes_of(rule), children: children)
  end

  # 系列が1つだけの指定科目は、入れ物にせず一文で出す(「大学英語 ＋ 英語講読演習 中級 を修得」)。
  def paths_card(rule, curriculum)
    paths = Array(rule['paths']).map { |path| path_text(path, curriculum) }
    name = rule['label'].presence || '指定科目'
    return RuleCard.new(id: rule['id'], name: name, note: notes_of(rule, "#{paths.first} を修得")) if paths.one?

    children = paths.map { |text| RuleCard.new(name: text) }
    RuleCard.new(id: rule['id'], name: name, badge: BADGES.fetch('paths'), note: notes_of(rule),
                 children: children)
  end

  # 算入上限は台帳全体に掛かる調整で、この行に閉じていない。その場に書いて取り違えを防ぐ。
  def cap_card(rule, curriculum)
    RuleCard.new(id: rule['id'], name: category_names(rule['category'], curriculum),
                 limit: rule['credits'], note: notes_of(rule, '便覧全体での卒業算入の上限'))
  end

  def unknown_card(definition)
    RuleCard.new(name: '解釈できない決まり', note: GraduationAssessment::Rules::Unknown.new(definition).reason)
  end

  # 入れ子の選択肢には label が無いので、数える区分の名前で呼ぶ。
  def rule_card_name(rule, curriculum)
    rule['label'].presence ||
      category_names(rule['categories'] || rule['category'] || rule['required_categories'], curriculum).presence ||
      '決まり'
  end

  def extra_note(rule, curriculum)
    case rule['type']
    when 'grouped_max' then "同一の#{group_label(rule)}から"
    when 'all_required' then "#{rule['expected_course_count']}科目すべてを修得（余剰単位での代用は不可）"
    when 'credit_sum' then category_note(rule, curriculum)
    end
  end

  # 複数の区分をまとめて数える合計は、どの区分を足すのかを添える(名前からは読み取れない)。
  def category_note(rule, curriculum)
    keys = Array(rule['categories'])
    "#{category_names(keys, curriculum)}の合計" if keys.size > 1
  end

  # 要確認の理由は、規則の一覧と同じ呼び方で出す(カードだけを読む人にも、何が起きると要確認かが伝わるように)。
  def notes_of(rule, *extra)
    review = "系列が混在したとき：#{rule['review_note']}" if rule['review_note'].present?
    (extra + [rule['detail'], review]).compact_blank.join('。').presence
  end
end

