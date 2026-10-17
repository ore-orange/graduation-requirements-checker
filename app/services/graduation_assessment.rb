# frozen_string_literal: true

require 'bigdecimal'

# 単位・科目要件の判定を永続化や画面から分離する。
# 履修状態は呼出側で明示し、成績から推測しない。
class GraduationAssessment
  Result = Data.define(:actual, :projected)
  Snapshot = Data.define(:status, :counted_credits, :checks, :review_notes, :course_results)
  Check = Data.define(
    :id, :label, :status, :counted_credits, :required_credits, :missing_courses, :source, :detail
  )
  CourseResult = Data.define(:key, :name, :credits, :counted_credits, :reason)

  def initialize(curriculum:)
    @curriculum = curriculum
  end

  def call(completed:, registered: [], planned: [], unresolved: [])
    catalogue = Catalogue.new(@curriculum)
    Result.new(
      actual: Evaluation.new(catalogue).call(completed, [], unresolved),
      projected: Evaluation.new(catalogue).call(completed, registered + planned, unresolved)
    )
  end
end

