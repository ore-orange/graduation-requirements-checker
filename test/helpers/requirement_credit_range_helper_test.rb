# frozen_string_literal: true

require 'test_helper'

# 「◯単位以上 〜 ◯単位以下」の部品(設計書 項目3)。章・枠・行・決まりで同じ形にする。
class RequirementCreditRangeHelperTest < ActionView::TestCase
  # 単位の数の書式(review_credits)と入力欄(rv_number)は、確認画面の部品と共通。
  include RequirementsReviewHelper

  # 入力欄(rv_*)は、保存できなかった送信の入力を残すために presenter を見る(RequirementsReview#field_value)。
  # ここで見たいのは欄の形だけなので、既定値をそのまま返す代役を置く。
  class NoSubmission
    def field_value(_name, default) = default
  end

  def requirements_review = NoSubmission.new

  # 必要単位(下限)も、代わりに出す言葉も無い行だけ「内数」と出す。文書には書き込まない(設計書 項目3)。
  test 'inner_row? は、必要単位も表示の言葉も無い行だけ true' do
    assert inner_row?({ 'required_credits' => nil, 'required_label' => nil })
    assert_not inner_row?({ 'required_credits' => 4, 'required_label' => nil })
    assert_not inner_row?({ 'required_credits' => nil, 'required_label' => '内数22単位枠' })
  end

  # 読むだけの枠には name を付けない。名前の無い欄はブラウザも送らないので、
  # 「触らずに保存したとき、文書が1バイトも変わらない」を壊さない。
  test 'credit_range は、読むだけの枠に name を付けない' do
    markup = Nokogiri::HTML5.fragment(credit_range(['row[required_credits]', 4], 2))

    assert_equal ['row[required_credits]'], markup.css('input').pluck('name')
    assert_match(/2/, markup.css('span').map(&:text).join)
  end

  # 章や枠が先に取った決まりを指すだけの行は、その数字を判定が使っていない。入力欄にせず、
  # どこに単位があるかを文で出す(設計書 項目1-2)。欄が無ければブラウザも送らない。
  test 'credit_range は、held_by を渡されたら入力欄を出さず「◯に含む」と書く' do
    markup = Nokogiri::HTML5.fragment(
      credit_range(['row[required_credits]', 22], nil, held_by: credits_held_by_text(['枠', '合計', 22]))
    )

    assert_empty markup.css('input')
    assert_equal '枠「合計」の22単位に含む', markup.text.strip
  end
end

