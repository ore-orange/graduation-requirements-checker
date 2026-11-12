# frozen_string_literal: true

# 算入しない科目(設計書 項目9)の欄。区分・提供コース(科目番号の接頭辞と、一致/以外)・名指しの科目番号。
# どれも「人が見る値」で、当たった科目の単位は修得していても消えるので、畳んだ中には入れない。
module RequirementsExcludeHelper
  # 提供コースの「一致 / 以外」。欄が無いときは「一致」(Rules::Exclude の既定)。
  PREFIX_MODES = [%w[一致 match], %w[以外 except]].freeze
  # 欄に添える言葉。何を書く欄なのかが、名前だけでは分からないもの。
  FIELD_HINTS = { 'number_prefix' => '(空ならすべての提供コース)', 'numbers' => '(カンマか空白で区切る)',
                  'category' => '(空ならすべての区分)' }.freeze

  # 提供コース(科目番号の接頭辞)の選択肢。当たる科目を例示する(接頭辞だけでは、何に当たるか分からない)。
  def prefix_select(name, selected, review)
    options = review.number_prefixes.map do |prefix, names|
      ["#{prefix}(#{names.first(2).join('・').presence || '科目表に該当なし'}#{" ほか#{names.size - 2}件" if names.size > 2})",
       prefix]
    end
    rv_select(name, options, selected, include_blank: true, id: nil, class: RequirementsReviewHelper::FIELD_CLASS)
  end

  # 「一致 / 以外」。欄が無いときは「一致」(Rules::Exclude の既定)を選んだ形で出す。
  def prefix_mode_picks(name, value)
    picks = PREFIX_MODES.map do |label, mode|
      tag.label(class: 'rv-pick text-xs') do
        radio_button_tag(name, mode, requirements_review.field_value(name, value.presence || 'match') == mode,
                         id: nil) + label
      end
    end
    tag.div(safe_join(picks, ' '), class: 'flex items-center gap-3')
  end

  # 名指しの科目番号。カンマ・空白区切りの1つの欄で書き、科目表のどの科目に当たるかを下に出す。
  def number_list_field(name, value, review)
    matched = review.named_courses(value).map { |number, found| "#{number}#{found ? "(#{found})" : '(科目表に無し)'}" }
    field = rv_text(name, Array(value).join('、'), id: nil,
                                                  class: "w-full #{RequirementsReviewHelper::FIELD_CLASS}")
    return field if matched.empty?

    safe_join([field, tag.p(matched.join('、'), class: 'text-xs text-slate-500')])
  end
end

