# frozen_string_literal: true

module CurriculumImport
  # 文書の科目表から、番号で区分が決まる科目を外す。絞り込みの実行を1か所にまとめたもの(判定は CourseFilter)。
  #
  # drop_confirmed が false なら、人が確認した科目・手で足した科目は残す(読み取り時と同じ)。
  # true なら、それらも外す。人が「外す」と決めた操作(候補の採用など)のためで、押す前に件数を見せること。
  # only は、区分のキーの配列。渡すと、その区分の number_patterns だけで判定する(採用した区分に当たる科目だけを外し、
  # 前から持っていた区分のパターンで、見せていない科目まで外さないため)。
  module CoursePrune
    HUMAN_MARKS = %w[confirmed added_by_hand].freeze

    # 外す科目の配列。文書は変えない(件数を先に見せるため)。
    def self.dropping(document, drop_confirmed:, only: nil)
      courses = document.is_a?(Hash) ? document['courses'] : nil
      return [] unless courses.is_a?(Array)

      filter = CourseFilter.new(judged(document, only))
      courses.select { |course| course.is_a?(Hash) && !filter.keep?(seen(course, drop_confirmed)) }
    end

    # 外した科目の配列。文書の courses から取り除く。
    def self.call(document, drop_confirmed:, only: nil)
      dropped = dropping(document, drop_confirmed: drop_confirmed, only: only)
      return dropped if dropped.empty?

      gone = dropped.index_with { |_course| true }.compare_by_identity
      document['courses'] = document['courses'].reject { |course| gone.key?(course) }
      dropped
    end

    # 人の印を見せない科目として判定にかける(判定そのものは CourseFilter に任せる)。
    def self.seen(course, drop_confirmed) = drop_confirmed ? course.except(*HUMAN_MARKS) : course

    def self.judged(document, only)
      return document if only.nil?

      document.merge('categories' => Array(document['categories']).select do |category|
        category.is_a?(Hash) && only.include?(category['key'])
      end)
    end
    private_class_method :judged
  end
end

