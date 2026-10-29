# frozen_string_literal: true

# 便覧の規則1つを、画面に出す一文（と、その下に続く入れ子）にする。確認画面の RequirementsHelper が使う。
# 型の語彙と置ける位置は評価側（GraduationAssessment::Rules）の定義に合わせ、ここで別に持たない。
module RuleSentenceHelper
  # 区分の和名（category_label）と単位の書式（credit_number）はこちらから借りる。
  include StudentWorkspaceHelper

  # 一文とその下に続く入れ子。connector は、並んだ項目どうしの間に出す「または」「かつ」。
  # unknown は、評価側が解釈できない（または何も主張しない）部分。入れ子の奥にあっても、上の規則から見つけられる。
  RuleNode = Struct.new(:text, :children, :connector, :unknown, keyword_init: true) do
    def initialize(text:, children: [], connector: nil, unknown: false) = super

    def contains_unknown? = unknown || children.any?(&:contains_unknown?)
  end

  # group_by が欄の名前（field:...）でないときの呼び名。
  GROUP_BY_NAMES = { 'number_prefix' => '科目番号の接頭辞' }.freeze

  # 画面に並べる規則。cap・exclude は判定を作らない調整だが、便覧の規則なので並べる。
  TOP_LEVEL_RULES = (GraduationAssessment::Rules::TOP_LEVEL + GraduationAssessment::Rules::ADJUSTMENTS.keys).freeze

  NODE_BUILDERS = { 'credit_sum' => :credit_sum_node, 'grouped_max' => :grouped_max_node,
                    'all_required' => :all_required_node, 'any_of' => :any_of_node,
                    'one_of_paths' => :one_of_paths_node, 'cap' => :cap_node, 'exclude' => :exclude_node }.freeze

  private

  # allowed に無い型は、評価側と同じく解釈できない規則にする。型を知っていても置けない位置なら、その旨を出す。
  def rule_node(definition, curriculum, allowed)
    return unknown_node(definition) unless allowed.include?(definition['type'])

    send(NODE_BUILDERS.fetch(definition['type']), definition, curriculum)
  end

  def unknown_node(definition)
    RuleNode.new(text: GraduationAssessment::Rules::Unknown.new(definition).reason, unknown: true)
  end

  def credit_sum_node(definition, curriculum) = RuleNode.new(text: credit_sum_text(definition, curriculum))

  def credit_sum_text(definition, curriculum)
    "#{category_names(definition['categories'], curriculum)}の合計 #{credits_at_least(definition['required_credits'])}"
  end

  def grouped_max_node(definition, curriculum) = RuleNode.new(text: grouped_max_text(definition, curriculum))

  def grouped_max_text(definition, curriculum)
    "#{category_names(definition['category'], curriculum)}のうち、同一の#{group_label(definition)}から " \
      "#{credits_at_least(definition['required_credits'])}"
  end

  def all_required_node(definition, curriculum) = RuleNode.new(text: all_required_text(definition, curriculum))

  def all_required_text(definition, curriculum)
    "#{category_names(definition['required_categories'], curriculum)}の必修科目 #{definition['expected_course_count']}科目" \
      "（計 #{credit_value(definition['required_credits'])}単位）をすべて修得"
  end

  def cap_node(definition, curriculum) = RuleNode.new(text: cap_text(definition, curriculum))

  def cap_text(definition, curriculum)
    "#{category_names(definition['category'], curriculum)}は卒業算入の上限 #{credit_value(definition['credits'])}単位"
  end

  def exclude_node(definition, curriculum) = RuleNode.new(text: exclude_text(definition, curriculum))

  def exclude_text(definition, curriculum)
    scope = category_names(definition['category'], curriculum)
    scope += "のうち科目番号が「#{definition['number_prefix']}」で始まる科目" if definition['number_prefix']
    "#{scope}は卒業単位に算入しない：#{definition['reason']}"
  end

  def any_of_node(definition, curriculum)
    options = Array(definition['options']).map do |option|
      option = {} unless option.is_a?(Hash)
      nested_node(option, curriculum, GraduationAssessment::Rules::ANY_OF_OPTIONS)
    end
    options = [empty_node('選択肢が空です')] if options.empty?
    RuleNode.new(text: '次のいずれかを満たす', children: options, connector: 'または')
  end

  # all_of は any_of の選択肢としてだけ置ける。条件は「かつ」でつなぐ。
  def all_of_node(definition, curriculum)
    conditions = Array(definition['conditions']).map do |condition|
      condition = {} unless condition.is_a?(Hash)
      nested_node(condition, curriculum, GraduationAssessment::Rules::ALL_OF_CONDITIONS)
    end
    conditions = [empty_node('条件が空です')] if conditions.empty?
    RuleNode.new(text: '次をすべて満たす', children: conditions, connector: 'かつ')
  end

  def nested_node(definition, curriculum, allowed)
    return all_of_node(definition, curriculum) if definition['type'] == 'all_of' && allowed.include?('all_of')

    rule_node(definition, curriculum, allowed)
  end

  # 子が1つも無い規則は何も主張しない。評価側も充足と答えないので、読める文のまま残さず赤で出す。
  # 空の系列も同じ。
  def one_of_paths_node(definition, curriculum)
    paths = Array(definition['paths']).map do |path|
      Array(path).empty? ? empty_node('系列が空です') : RuleNode.new(text: path_text(path, curriculum))
    end
    return RuleNode.new(text: "次を修得する：#{paths.first.text}") if paths.one? && !paths.first.unknown

    paths = [empty_node('系列が空です')] if paths.empty?
    RuleNode.new(text: '次のいずれかの系列を修得する', children: paths, connector: 'または')
  end

  def empty_node(text) = RuleNode.new(text: text, unknown: true)

  # 系列は役割（role）の組。役割は科目表の科目に付いているので、科目名に戻して出す。同じ役割の科目は「／」、組は「＋」。
  def path_text(path, curriculum)
    Array(path).map do |role|
      names = curriculum.fetch('courses').select { |course| Array(course['roles']).include?(role) }.pluck('name')
      names.empty? ? "#{role}（科目表に該当なし）" : names.join('／')
    end.join(' ＋ ')
  end

  def category_names(keys, curriculum)
    Array(keys).map { |key| category_label(key, curriculum) }.join('・')
  end

  def group_label(definition)
    return definition['group_label'] if definition['group_label'].present?

    group_by = definition['group_by'].to_s
    field_group = GraduationAssessment::Ledger::FIELD_GROUP
    return group_by.delete_prefix(field_group) if group_by.start_with?(field_group)

    GROUP_BY_NAMES.fetch(group_by, group_by)
  end

  def credits_at_least(value) = value.is_a?(Numeric) ? "#{credit_number(value)}単位以上" : '必要単位が未設定'
  def credit_value(value) = value.is_a?(Numeric) ? credit_number(value) : '未設定'
end

