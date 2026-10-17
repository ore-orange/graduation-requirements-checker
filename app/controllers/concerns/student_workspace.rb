# frozen_string_literal: true

# 学生1人分の履修データと卒業要件を読み込み、各画面に渡す。
# 認証が入るまでは固定のデモ学生をローカル環境でのみ扱う。
module StudentWorkspace
  extend ActiveSupport::Concern

  CURRENT_STATUSES = %w[registered in_progress].freeze

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
    @curriculum = CurriculumRepository.find(department: 'intelligent_informatics', admission_year: 2024)
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

  def show_setup
    render 'shared/setup', status: :service_unavailable
  end
end

