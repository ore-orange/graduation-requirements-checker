# frozen_string_literal: true

# 要件表の確認画面の「◯単位以上 〜 ◯単位以下」(設計書 項目3)。
# 章・枠・行・決まりで同じ形にするための部品を、ここにまとめる。
module RequirementCreditRangeHelper
  # 「◯以上 〜 ◯以下」の2つの欄。章・枠・行・決まりで同じ形にする。
  # lower・upper は [欄の名前, 値] なら入力欄、それ以外(数・nil)は読むだけの枠。
  # 読むだけの枠には name を付けない。名前の無い欄はブラウザも送らないので、
  # 「触らずに保存したとき、文書が1バイトも変わらない」を壊さない。
  # held_by が渡されたら、2つの欄の代わりに「◯に含む」の文を出す。その行の数字は判定が使っていないので、
  # 入力欄にすると「直しても判定が動かない」落とし穴になる(設計書 項目1-2)。
  def credit_range(lower, upper, note: nil, held_by: nil)
    return tag.span(held_by, class: 'rv-slot whitespace-nowrap') if held_by

    parts = [credit_slot(lower, '下限なし(数えるだけ)'), tag.span('〜', class: 'text-slate-400'),
             credit_slot(upper, '上限なし'), tag.span('単位', class: 'font-medium text-slate-600')]
    parts << tag.span(note, class: 'text-amber-800') if note
    tag.span(safe_join(parts, ' '), class: 'inline-flex items-center gap-1 whitespace-nowrap text-xs')
  end

  # 行の単位を、どの章・枠が持っているかの文。credit_range の held_by に渡す。
  def credits_held_by_text(holder)
    kind, name, credits = holder
    "#{kind}「#{name}」の#{review_credits(credits)}単位に含む"
  end

  def credit_slot(slot, title)
    if slot.is_a?(Array)
      return rv_number(slot.first, slot.last, id: nil,
                                              class: 'w-16 text-right tabular-nums ' \
                                                     "#{RequirementsReviewHelper::FIELD_CLASS}")
    end

    tag.span(review_credits(slot), title: slot.nil? ? title : nil, class: 'rv-slot')
  end

  # 必要単位(下限)も、その代わりに出す言葉も無い行。学生の画面では上の章の単位に含まれる。
  # 「内数」は画面にだけ出し、文書には書き込まない(設計書 項目3)。
  def inner_row?(row) = row['required_credits'].nil? && row['required_label'].blank?
end

