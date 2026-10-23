# frozen_string_literal: true

# 履修計画表の学期（{ grade: 2, semester: '後期' }）を表示・URL 用の文字にする。
module PlansHelper
  def term_param(term) = "#{term[:grade]}-#{term[:semester]}"
  def term_label(term) = "#{term[:grade]}年 #{term[:semester]}"
end

