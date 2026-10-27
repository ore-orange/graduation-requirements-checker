# frozen_string_literal: true

# 学生1人分の履修データと卒業要件を読み込み、各画面に渡す。
# 認証が入るまでは固定のデモ学生をローカル環境でのみ扱う。
module StudentWorkspace
  extend ActiveSupport::Concern

  CURRENT_STATUSES = %w[registered in_progress].freeze
  # 学期は { grade: 2, semester: '後期' } で表し、1年前期〜4年後期を時系列順に並べる。
  SEMESTERS = %w[前期 後期].freeze
  TERMS = (1..4).flat_map { |grade| SEMESTERS.map { |semester| { grade: grade, semester: semester } } }.freeze
  TERM_PARAM = /\A(?<grade>[1-4])-(?<semester>前期|後期)\z/

  included do
    before_action :require_local_demo
    before_action :load_workspace

    rescue_from DemoAccount::Unavailable, with: :show_setup
  end

  private

  def require_local_demo
    head :not_found unless local_demo_access?
  end

  # 全画面で必要になる最小限。履修履歴は使う画面だけが enrollments で読む。
  def load_workspace
    @student = DemoAccount.student
    @curriculum = CurriculumRepository.find(department: DemoAccount::DEPARTMENT,
                                            admission_year: @student.admission_year)
    @courses_by_key = @curriculum.fetch('courses').index_by { |course| course.fetch('key') }
  end

  def enrollments
    @enrollments ||= @student.student_courses.includes(:course).order(:academic_year, :id).to_a
  end

  def load_plans
    @plans = @student.planned_courses.includes(:course).order(:id).to_a
  end

  def load_history
    enrollments
    @completed = @enrollments.select { |enrollment| enrollment.enrollment_status == 'completed' }
    @current = @enrollments.select { |enrollment| CURRENT_STATUSES.include?(enrollment.enrollment_status) }
    @other_enrollments = @enrollments - @completed - @current
  end

  def assess
    unresolved = @other_enrollments.select { |enrollment| enrollment.enrollment_status == 'unknown' }
    GraduationAssessment.new(curriculum: @curriculum).call(
      completed: @completed.map(&:assessment_entry),
      registered: @current.map(&:assessment_entry),
      planned: @plans.map { |plan| planned_entry(plan) },
      unresolved: unresolved.map(&:assessment_entry)
    )
  end

  def planned_entry(plan)
    course = @courses_by_key[plan.course.curriculum_key]
    credits = course ? course.fetch('credits') : plan.course.credits
    { key: plan.course.curriculum_key, credits: credits, approved: nil, name: plan.course.name }
  end

  # URL の "2-後期" を学期にする。読めない値は nil。
  def parse_term(value)
    match = TERM_PARAM.match(value.to_s)
    { grade: match[:grade].to_i, semester: match[:semester] } if match
  end

  # 年度は4月始まりで、4〜9月を前期、10〜3月を後期とする。在学期間の外なら端の学期にする。
  def current_term(date = Date.current)
    academic_year = date.month >= 4 ? date.year : date.year - 1
    semester_index = date.month.between?(4, 9) ? 0 : 1
    TERMS[(((academic_year - @student.admission_year) * SEMESTERS.size) + semester_index).clamp(0, TERMS.size - 1)]
  end

  # 履修履歴・予定の年度と学期から学期を求める。入学前・5年目以降は1年・4年に寄せる。学期が不明なら nil。
  def term_of(record)
    return unless SEMESTERS.include?(record.semester)

    { grade: (record.academic_year - @student.admission_year + 1).clamp(1, 4), semester: record.semester }
  end

  def term_year(term) = @student.admission_year + term[:grade] - 1

  # 予定を追加できるのは今の学期とそれ以降。
  def term_open?(term) = TERMS.index(term) >= TERMS.index(current_term)

  def show_setup
    render 'shared/setup', status: :service_unavailable
  end
end

