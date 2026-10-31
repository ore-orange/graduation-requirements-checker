# frozen_string_literal: true

module PlansHelper
  include StudentWorkspaceHelper

  # 履修計画表の学期（{ grade: 2, semester: '後期' }）を表示・URL 用の文字にする。
  def term_param(term) = "#{term[:grade]}-#{term[:semester]}"
  def term_label(term) = "#{term[:grade]}年 #{term[:semester]}"

  # 区分ごとの必要単位がなく、合計で数える区分のまとまり。計画表では合計と必要単位を1か所にまとめて出す。
  # 便覧の display の小計のうち、その行を含むもの。
  def planner_subtotal_for(row_id, curriculum)
    subtotal = curriculum.fetch('display').fetch('subtotals').find { |entry| entry.fetch('row_ids').include?(row_id) }
    display_entry(subtotal) if subtotal
  end

  # 承認の3択（あり・なし・未回答）。値は approval_confirmed にそのまま書く値（nilは未回答に戻す）。
  def approval_choices = [[true, '承認あり'], [false, '承認なし'], [nil, '未回答']]

  def approval_button_class(selected)
    base = 'px-1.5 py-0.5 rounded text-[10px] font-semibold border cursor-pointer'
    return "#{base} bg-amber-600 text-white border-amber-600" if selected

    "#{base} bg-white border-amber-200 text-amber-800 hover:bg-amber-50"
  end
end

