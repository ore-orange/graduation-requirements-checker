# frozen_string_literal: true

class DemoController < ApplicationController
  CURRENT_STATUSES = %w[registered in_progress].freeze
  BLOCKED_STATUSES = %w[completed registered in_progress].freeze
  CUSTOM_CATEGORIES = (GraduationAssessment::Catalogue::CATEGORIES - ['excluded']).freeze
  before_action :require_local_demo
  before_action :load_demo

  rescue_from DemoAccount::Unavailable, with: :show_setup

  # 進捗ダッシュボード
  def show
    load_history
    load_plans
    @assessment = assess
  end

  # 卒業要件の編集。要件ツリーは @curriculum だけで描画できる
  def builder; end

  # 履修計画表。科目を検索して追加するため科目一覧も読む
  def planner
    load_history
    load_plans
    @assessment = assess
    load_catalogue
  end

  # マイページ
  def profile
    load_history
    load_plans
  end

  def create
    course = selectable_course
    return redirect_to plan_path, alert: '追加できる科目を科目一覧から選択してください。', status: :see_other unless course

    if unavailable_course?(course)
      return redirect_to plan_path, alert: 'この科目は修得済み・履修中、または追加済みです。',
                                    status: :see_other
    end

    @student.planned_courses.create!(course: course)
    redirect_to plan_path, notice: '今後の履修予定に追加しました。判定を更新しました。', status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to plan_path, alert: '科目を追加できませんでした。既に追加されていないか確認してください。', status: :see_other
  end

  def destroy
    plan = @student.planned_courses.find_by(id: params[:id])
    return head :not_found unless plan

    course = plan.course
    plan.destroy!
    cleanup_custom_course(course)
    redirect_to plan_path, notice: '今後の履修予定から削除しました。判定を更新しました。', status: :see_other
  end

  private

  def require_local_demo
    head :not_found unless local_demo_access?
  end

  def load_demo
    @student = DemoAccount.student
    @curriculum = CurriculumRepository.find(department: 'intelligent_informatics', admission_year: 2024)
    @courses_by_key = @curriculum.fetch('courses').index_by { |course| course.fetch('key') }
    @enrollments = @student.student_courses.includes(:course).order(:academic_year, :id).to_a
  end

  def load_plans
    @plans = @student.planned_courses.includes(:course).order(:id).to_a
  end

  def load_history
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

  def load_catalogue
    @unavailable_keys = (@completed + @current).map { |enrollment| enrollment.course.curriculum_key } +
                        @plans.map { |plan| plan.course.curriculum_key }
    @query = params[:q].to_s.strip
    @category = params[:category].to_s
    query = @query.downcase
    @catalogue = @curriculum.fetch('courses').select do |course|
      (@category.blank? || course['category'] == @category) && matches_query?(course, query)
    end
    keys = @catalogue.map { |course| course.fetch('key') }
    @persisted_keys = Course.where(curriculum_key: keys).pluck(:curriculum_key)
  end

  def matches_query?(course, query)
    query.blank? || [course['name'], course['number'], course['key']].compact.any? do |value|
      value.downcase.include?(query)
    end
  end

  def selectable_course
    return build_custom_course if params[:custom_course].present?

    key = params.permit(:course_key)[:course_key]
    find_catalogue_course(key) if key.is_a?(String)
  end

  def find_catalogue_course(key)
    catalogue_course = @courses_by_key[key]
    return unless catalogue_course && catalogue_course['selectable'] == true

    Course.find_by(curriculum_key: key) ||
      raise(DemoAccount::Unavailable, 'Catalogue courses have not been seeded')
  end

  def build_custom_course
    attrs = custom_course_attributes
    return unless attrs

    matched = match_catalogue_course(attrs[:name], attrs[:number])
    return find_catalogue_course(matched.fetch('key')) if matched

    Course.create!(curriculum_key: "custom:#{attrs[:category]}:#{SecureRandom.hex(6)}",
                   course_number: attrs[:number], name: attrs[:name], credits: attrs[:credits])
  end

  def custom_course_attributes
    raw = params.expect(custom_course: %i[name course_number credits category])
    name = raw[:name].to_s.strip
    category = raw[:category].to_s.strip
    credits = BigDecimal(raw[:credits].to_s, exception: false)
    return unless name.present? && CUSTOM_CATEGORIES.include?(category) && credits&.positive? && credits < 100

    { name: name, number: raw[:course_number].to_s.strip.presence, category: category, credits: credits }
  rescue ActionController::ParameterMissing, ActionController::UnpermittedParameters
    nil
  end

  def match_catalogue_course(name, number)
    @curriculum.fetch('courses').find do |course|
      course['name'].casecmp?(name) || (number.present? && course['number'].to_s.casecmp?(number))
    end
  end

  def cleanup_custom_course(course)
    return unless course.curriculum_key.to_s.start_with?('custom:')
    return if course.planned_courses.exists? || course.student_courses.exists?

    course.destroy!
  end

  def unavailable_course?(course)
    @enrollments.any? do |enrollment|
      enrollment.course_id == course.id && BLOCKED_STATUSES.include?(enrollment.enrollment_status)
    end || @student.planned_courses.exists?(course_id: course.id)
  end

  def planned_entry(plan)
    course = @courses_by_key[plan.course.curriculum_key]
    credits = course ? course.fetch('credits') : plan.course.credits
    { key: plan.course.curriculum_key, credits: credits, approved: nil, name: plan.course.name }
  end

  def show_setup
    render :setup, status: :service_unavailable
  end
end

