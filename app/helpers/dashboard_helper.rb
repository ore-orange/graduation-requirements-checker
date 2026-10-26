# frozen_string_literal: true

module DashboardHelper
  # 「1. 共通教育」のような通し番号は、ダッシュボードでは並び順で分かるので落とす
  def group_short_title(definition) = definition[:title].sub(/\A\d+\.\s*/, '')

  # 区分カードの見出しに添える目印。区分を見分けやすくするためだけのもの。
  GROUP_ICONS = {
    'common' => 'M3 4h5a2 2 0 0 1 2 2v10a2 2 0 0 0-2-2H3V4Zm14 0h-5a2 2 0 0 0-2 2v10a2 2 0 0 1 2-2h5V4Z',
    'basic' => 'M10 2 3 6l7 4 7-4-7-4ZM3 10l7 4 7-4M3 14l7 4 7-4',
    'required' => 'M13.5 2.5a2.12 2.12 0 0 1 3 3L8 14l-4 1 1-4 8.5-8.5ZM3 17h14',
    'elective' => 'M3 5h2v2H3V5Zm4 .5h10v1H7v-1ZM3 9h2v2H3V9Zm4 .5h10v1H7v-1ZM3 13h2v2H3v-2Zm4 .5h10v1H7v-1Z'
  }.freeze

  def group_icon_path(definition) = GROUP_ICONS.fetch(definition[:id], GROUP_ICONS['elective'])
end

