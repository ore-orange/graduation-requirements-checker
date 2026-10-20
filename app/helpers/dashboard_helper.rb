# frozen_string_literal: true

module DashboardHelper
  # 「1. 共通教育」のような通し番号は、ダッシュボードでは並び順で分かるので落とす
  def group_short_title(definition) = definition[:title].sub(/\A\d+\.\s*/, '')
end

