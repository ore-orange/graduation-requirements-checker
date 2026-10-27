# frozen_string_literal: true

# 保存済みの講義の絞り込み。管理者が「指摘を受けた講義を探す」ための引き当てに使う。
#
# 学期は軸に入れない(表の列としてだけ出す)。年度・学科が空の講義(#53 のあとに残る
# curriculum_key 由来のもの)は、その軸を指定していないときは落とさない。
class CourseOfferingSearch
  # 完全一致で当てる軸と、部分一致で当てる軸
  EXACT_KEYS = %i[year faculty_id department_id].freeze
  PARTIAL_KEYS = %i[course_number lecture_code name].freeze
  KEYS = (EXACT_KEYS + PARTIAL_KEYS).freeze

  def initialize(params)
    @conditions = KEYS.filter_map { |key| [key, params[key].to_s.strip] if params[key].to_s.strip.present? }.to_h
  end

  # ページ送りのリンクとフォームの再表示に使う、指定のあった条件だけ
  attr_reader :conditions

  def filtered?
    conditions.any?
  end

  def relation
    scope = CourseOffering.includes(:course, department: :faculty)
    scope = scope.where(year: conditions[:year]) if conditions[:year]
    scope = narrow_by_organization(scope)
    scope = narrow_by_text(scope)
    scope.order(year: :desc).order(:semester, :weekday, :periods, :id)
  end

  private

  # 学部は departments を経由して絞る。学科と両方の指定があれば、両方を満たすものだけ。
  def narrow_by_organization(scope)
    departments = Department.all
    departments = departments.where(faculty_id: conditions[:faculty_id]) if conditions[:faculty_id]
    departments = departments.where(id: conditions[:department_id]) if conditions[:department_id]
    return scope unless conditions[:faculty_id] || conditions[:department_id]

    scope.where(department_id: departments.select(:id))
  end

  def narrow_by_text(scope)
    if (code = conditions[:lecture_code])
      scope = scope.where('course_offerings.lecture_code ILIKE ?', contains(code))
    end
    return scope unless conditions[:course_number] || conditions[:name]

    scope = scope.joins(:course)
    if conditions[:course_number]
      scope = scope.where('courses.course_number ILIKE ?',
                          contains(conditions[:course_number]))
    end
    conditions[:name] ? scope.where('courses.name ILIKE ?', contains(conditions[:name])) : scope
  end

  # 部分一致。打たれた「%」「_」は、LIKEの記号ではなく文字そのものとして探す。
  def contains(text)
    "%#{ActiveRecord::Base.sanitize_sql_like(text)}%"
  end
end

