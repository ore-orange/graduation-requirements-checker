# frozen_string_literal: true

# 判定結果の表示。判定(充足/不足)と、履修中・要確認という別軸の付記を分けて扱う。
module AssessmentStatusHelper
  # 判定そのものは充足か不足。needs_review は「不足と言い切れない」状態で、
  # 履修計画表のように付記を並べられない場所ではこの名前で出す。
  STATUS_LABELS = { satisfied: '充足', unmet: '不足', needs_review: '要確認' }.freeze
  STATUS_CLASSES = { satisfied: 'status-satisfied', unmet: 'status-unmet', needs_review: 'status-review' }.freeze

  def assessment_status_label(status) = STATUS_LABELS.fetch(status)
  def assessment_status_class(status) = STATUS_CLASSES.fetch(status)

  # 充足していても追加で履修することはあるので、判定と履修中は同時に出す。
  # 要確認は「不足と言い切れない」状態なので、不足のときだけ添える。
  def status_badges(summary)
    badges = [[assessment_status_label(summary[:status]), assessment_status_class(summary[:status])]]
    badges << %w[履修中 status-in-progress] if summary[:planned].positive?
    badges << %w[要確認 status-review] if summary[:review]
    badges
  end
end

