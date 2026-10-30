# frozen_string_literal: true

# 要件表の確認画面(curricula/_requirements_*)の部品。値の書式と、フォームの欄の名前・種類をここに集める。
module RequirementsReviewHelper
  RULE_TYPE_NAMES = { 'credit_sum' => '区分の合計単位', 'all_required' => '必修をすべて修得', 'one_of_paths' => '指定科目の系列',
                      'grouped_max' => '同じ提供元・言語から', 'any_of' => 'どれか1つを満たす', 'all_of' => 'すべてを満たす',
                      'cap' => '算入の上限', 'exclude' => '算入しない' }.freeze
  FIELD_NAMES = CurriculumImport::RequirementsEdit::FIELD_LABELS
  SUMMARY_FIELDS = %w[categories required_categories category required_credits expected_course_count group_by].freeze
  FIELD_CLASS = 'rounded border border-slate-300 bg-white px-2 py-1.5 text-sm'

  # 単位の数。整数なら小数点を付けない。無ければダッシュ。
  def review_credits(value)
    return '—' unless value.is_a?(Numeric)

    value.to_d.then { |number| number.frac.zero? ? number.to_i.to_s : number.to_s('F') }
  end

  def rule_type_name(type)
    RULE_TYPE_NAMES.fetch(type, type.presence || '(型なし)')
  end

  # 規則の中身を、画面が一覧できる短い文にする。入れ子や経路は、JSON で見られるので件数だけにする。
  def rule_summary(rule, review)
    fields = SUMMARY_FIELDS.filter_map do |field|
      "#{FIELD_NAMES.fetch(field)}: #{summary_value(rule[field], field, review)}" if rule.key?(field)
    end
    fields + nested_summary(rule)
  end

  def nested_summary(rule)
    { 'paths' => '経路', 'options' => '選択肢', 'conditions' => '条件' }.filter_map do |field, name|
      "#{name}: #{rule[field].size}件" if rule[field].is_a?(Array)
    end
  end

  def summary_value(value, field, review)
    return review_credits(value) if value.is_a?(Numeric)
    return '(空)' if value.nil?

    names = Array(value).map { |key| category_field?(field) ? review.category_label(key) : key.to_s }
    names.join('・').presence || '(空)'
  end

  def category_field?(field) = %w[categories required_categories category].include?(field)

  # 区分を選ぶチェックの並び。1つも選ばないときも「空にする」と伝わるよう、先に空の値を送る。
  def category_checks(name, selected, review)
    boxes = review.category_keys.map do |key|
      tag.label(class: 'inline-flex items-center gap-1 whitespace-nowrap text-xs text-slate-800') do
        check_box_tag("#{name}[]", key, Array(selected).include?(key), id: nil) + review.category_label(key)
      end
    end
    hidden_field_tag("#{name}[]", '', id: nil) + tag.div(safe_join(boxes), class: 'flex flex-wrap gap-x-3 gap-y-1')
  end

  # 規則の1つの欄の入力。欄の種類は RequirementsEdit.rule_fields と同じ表から決まる。
  def rule_field_input(name, field, kind, rule, review)
    label = tag.span(FIELD_NAMES.fetch(field, field), class: 'text-xs font-semibold text-slate-700')
    tag.div(label + rule_field_control(name, field, kind, rule[field], review), class: 'space-y-1')
  end

  def rule_field_control(name, field, kind, value, review)
    case kind
    when :set then category_checks(name, value, review)
    when :number then number_field_tag(name, value, step: 'any', class: "w-28 #{FIELD_CLASS}")
    when :count then number_field_tag(name, value, step: 1, class: "w-28 #{FIELD_CLASS}")
    else if field == 'category'
           category_select(name, value,
                           review)
         else
           text_field_tag(name, value, class: "w-full #{FIELD_CLASS}")
         end
    end
  end

  def category_select(name, selected, review)
    options = review.category_keys.map { |key| [review.category_label(key), key] }
    select_tag(name, options_for_select(options, selected), include_blank: true, class: FIELD_CLASS)
  end

  # JSON の欄に出す規則。confirmed は人が直した印で、直す対象ではないので出さない。
  def rule_json(rule)
    JSON.pretty_generate(rule.except(CurriculumImport::DraftMerge::CONFIRMED))
  end

  def human_confirmed?(item) = item[CurriculumImport::DraftMerge::CONFIRMED] == true

  def annotation_type_options
    CurriculumImport::Annotations::RULE_TYPES.map { |type| ["規則にする: #{rule_type_name(type)}(#{type})", type] }
  end
end

