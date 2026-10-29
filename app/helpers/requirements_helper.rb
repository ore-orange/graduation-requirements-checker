# frozen_string_literal: true

# 卒業要件の確認画面。便覧の規則（rules）を、型ごとに人が読める一文にして出す。
# 画面は便覧に書かれた内容を見せるだけなので、判定の途中経過（算入単位や不足）はここでは扱わない。
module RequirementsHelper
  include RuleSentenceHelper

  RULE_KINDS = { 'credit_sum' => '単位の合計', 'any_of' => '選択', 'one_of_paths' => '指定科目', 'grouped_max' => '同一グループ',
                 'all_required' => '必修すべて', 'cap' => '算入上限', 'exclude' => '算入しない' }.freeze

  KIND_BADGE_CLASS = 'mt-0.5 shrink-0 rounded-md bg-slate-100 px-1.5 py-0.5 text-[11px] font-semibold text-slate-600'

  # 規則1つぶんの <li>。解釈できない規則は、飛ばさずに赤く出す。
  def rule_entry(rule, curriculum)
    definition = rule.is_a?(Hash) ? rule : {}
    node = rule_node(definition, curriculum, TOP_LEVEL_RULES)
    data = { rule_id: definition['id'], rule_type: definition['type'],
             rule_status: ('unknown' if node.contains_unknown?) }
    tag.li(class: 'py-4', data: data) do
      safe_join([rule_headline(rule, definition, node), rule_children(node),
                 nested_unknown_notice(rule, definition, node), rule_notes(definition)].compact)
    end
  end

  private

  def rule_headline(rule, definition, node)
    return unknown_headline(rule, definition, node) if node.unknown

    label = definition['label'].presence
    sentence = label ? safe_join([tag.span(label, class: 'font-semibold text-slate-900'), '：', node.text]) : node.text
    tag.div(class: 'flex items-start gap-2') do
      safe_join([tag.span(RULE_KINDS.fetch(definition['type']), data: { rule_kind: true }, class: KIND_BADGE_CLASS),
                 tag.p(sentence, class: 'min-w-0 text-sm text-slate-700')])
    end
  end

  def unknown_headline(rule, definition, node)
    tag.div(class: 'space-y-0.5 text-red-700') do
      safe_join([tag.p("#{node.text}。判定では充足とせず、要確認になります。", class: 'text-sm font-semibold'),
                 rule_locator(rule, definition)].compact)
    end
  end

  # 規則そのものは読めるが、中に読めない部分がある。一覧を眺めて見つけられるよう、規則の側でも赤く知らせる。
  def nested_unknown_notice(rule, definition, node)
    return if node.unknown || !node.contains_unknown?

    tag.div(class: 'mt-2 space-y-0.5 text-red-700') do
      safe_join([tag.p('この規則には、このアプリが解釈できない部分があります。判定では充足とせず、要確認になります。',
                       class: 'text-sm font-semibold'),
                 rule_locator(rule, definition)].compact)
    end
  end

  # 27件の中から探せるよう、規則の id とラベルを添える。
  def rule_locator(rule, definition)
    where = [("id: #{definition['id']}" if definition['id']), definition['label'].presence].compact
    where << "内容: #{rule.inspect.truncate(80)}" unless rule.is_a?(Hash)
    tag.p(where.join('／'), class: 'text-xs') if where.any?
  end

  def rule_children(node)
    return if node.children.empty?

    tag.ul(class: 'mt-2 space-y-2 border-l-2 border-slate-200 pl-3') do
      safe_join(node.children.each_with_index.map { |child, index| rule_child(node, child, index) })
    end
  end

  def rule_child(parent, child, index)
    tag.li(class: 'flex items-start gap-2') do
      safe_join([tag.span(index.zero? ? '' : parent.connector,
                          class: 'mt-0.5 w-10 shrink-0 text-xs font-semibold text-slate-400'),
                 tag.div(class: 'min-w-0') do
                   safe_join([tag.p(child.text, class: ['text-sm', child.unknown ? 'text-red-700' : 'text-slate-700']),
                              rule_children(child)].compact)
                 end])
    end
  end

  # 便覧の備考と出典。照らし合わせる相手は印刷された便覧なので、出典のページを必ず添える。
  def rule_notes(definition)
    notes = [['備考', definition['detail']],
             ['系列が混在したとき', (definition['review_note'] if definition['type'] == 'one_of_paths')],
             ['出典', definition['source_page']]].to_h.compact_blank
    return if notes.empty?

    tag.div(class: 'mt-1.5 space-y-0.5 text-xs text-slate-500') do
      safe_join(notes.map { |name, text| tag.p("#{name}：#{text}") })
    end
  end
end

