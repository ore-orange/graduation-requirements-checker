# frozen_string_literal: true

module TimetableImport
  # CSV・PDF解析・モデルで共有する語彙。Railsに依存しない。
  module Values
    SEMESTERS = %w[前期 後期].freeze
    REQUIREMENT_TYPES = %w[必修 選択].freeze
    WEEKDAYS = %w[月 火 水 木 金 土].freeze
    # 「3・4」「2,3」のような数字の並び
    DIGIT_LIST = /\A\d([・,]\d)*\z/
  end
end

