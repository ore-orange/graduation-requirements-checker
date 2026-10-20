# frozen_string_literal: true

# 判定結果のステータス表示。画面に出す言い回しはこの4つに揃える。
module AssessmentStatusHelper
  STATUS_LABELS = { satisfied: '充足', projected: '見込み充足', unmet: '不足あり', needs_review: '要確認' }.freeze
  STATUS_CLASSES = { satisfied: 'status-satisfied', projected: 'status-projected',
                     unmet: 'status-unmet', needs_review: 'status-review' }.freeze

  def assessment_status_label(status) = STATUS_LABELS.fetch(status)
  def assessment_status_class(status) = STATUS_CLASSES.fetch(status)
end

