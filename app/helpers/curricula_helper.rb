# frozen_string_literal: true

# 読み取った要件表を、人がPDFと見比べられる文にする。
module CurriculaHelper
  PAGE_STATUS_CLASSES = { 'pending' => 'bg-slate-100 text-slate-700', 'reading' => 'bg-sky-50 text-sky-800',
                          'read' => 'bg-emerald-50 text-emerald-800', 'failed' => 'bg-rose-50 text-rose-800',
                          'interrupted' => 'bg-amber-50 text-amber-800' }.freeze
  GROUP_FIELDS = { 'provider' => '提供コース', 'language' => '言語' }.freeze
  # 規則の型ごとの、文にするメソッド。どれも (rule, labels, roles) を受ける。
  SENTENCES = {
    'credit_sum' => :credit_sum_sentence, 'grouped_max' => :grouped_sentence, 'one_of_paths' => :paths_sentence,
    'all_required' => :all_required_sentence, 'any_of' => :any_of_sentence, 'all_of' => :all_of_sentence,
    'cap' => :cap_sentence, 'exclude' => :exclude_sentence
  }.freeze

  def page_status_badge(status)
    tag.span(Curriculum::PAGE_STATUS_LABELS.fetch(status, status),
             class: ['demo-status', PAGE_STATUS_CLASSES.fetch(status, PAGE_STATUS_CLASSES['pending'])])
  end

  # 規則1つを文にする。labels は { 区分の key => 和名 }、roles は { 役割の key => 呼び名 }。
  def rule_sentence(rule, labels, roles = {})
    method = SENTENCES[rule['type']]
    return 'この条件は、読み取った形が分からないため表示できません。' unless method

    send(method, rule, labels, roles)
  end

  # 規則の見出し。上限・除外(調整)は見出しを持たないので、はたらきで呼ぶ。
  def rule_title(rule)
    rule['label'].presence || (rule['type'].in?(%w[cap exclude]) ? '算入の調整' : rule['id'])
  end

  # 区分の和名。読み取った区分に無い key は、それと分かるように出す。
  def label_for(key, labels)
    labels.fetch(key) { "読み取れていない科目区分(#{key})" }
  end

  private

  def categories_text(keys, labels)
    Array(keys).map { |key| label_for(key, labels) }.join('・')
  end

  def credit_sum_sentence(rule, labels, _roles)
    "#{categories_text(rule['categories'], labels)}の合計 #{rule['required_credits']}単位以上"
  end

  def cap_sentence(rule, labels, _roles)
    "#{label_for(rule['category'], labels)}は#{rule['credits']}単位まで算入"
  end

  def grouped_sentence(rule, labels, _roles)
    field = rule['group_by'].to_s.delete_prefix('field:')
    "#{label_for(rule['category'], labels)}を#{GROUP_FIELDS.fetch(field, field)}ごとに数え、" \
      "同じ#{GROUP_FIELDS.fetch(field, field)}から #{rule['required_credits']}単位以上"
  end

  def any_of_sentence(rule, labels, roles)
    "次のどれか: #{Array(rule['options']).map { |option| rule_sentence(option, labels, roles) }.join(' 又は ')}"
  end

  def all_of_sentence(rule, labels, roles)
    "(#{Array(rule['conditions']).map { |condition| rule_sentence(condition, labels, roles) }.join(' かつ ')})"
  end

  def all_required_sentence(rule, labels, _roles)
    "必修#{rule['expected_course_count']}科目(#{rule['required_credits']}単位)をすべて修得" \
      "(#{categories_text(rule['required_categories'], labels)})"
  end

  def paths_sentence(rule, _labels, roles)
    texts = Array(rule['paths']).map { |path| Array(path).map { |role| roles.fetch(role, role) }.join('＋') }
    texts.one? ? "#{texts.first}を修得" : "次の組のどれか1つを丸ごと修得: #{texts.join(' ／ ')}"
  end

  def exclude_sentence(rule, labels, _roles)
    target = label_for(rule['category'], labels)
    target += "のうち#{GROUP_FIELDS.fetch(rule['field'], rule['field'])}が#{rule['value']}の科目" if rule['field'].present?
    "#{target}は算入しない(#{rule['reason']})"
  end
end

