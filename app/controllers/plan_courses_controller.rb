# frozen_string_literal: true

# 履修計画への科目の追加と削除。
class PlanCoursesController < ApplicationController
  include StudentWorkspace

  BLOCKED_STATUSES = %w[completed registered in_progress].freeze
  CUSTOM_CATEGORIES = (GraduationAssessment::Catalogue::CATEGORIES - ['excluded']).freeze

  def create
    course = selectable_course
    return redirect_to plan_path, alert: '追加できる科目を科目一覧から選択してください。', status: :see_other unless course

    return redirect_to plan_path, alert: 'この科目は修得済み・履修中、または追加済みです。', status: :see_other if unavailable_course?(course)

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
    credits = custom_credits(raw[:credits])
    return unless name.present? && CUSTOM_CATEGORIES.include?(category) && credits

    { name: name, number: raw[:course_number].to_s.strip.presence, category: category, credits: credits }
  rescue ActionController::ParameterMissing, ActionController::UnpermittedParameters
    nil
  end

  # 単位数は整数カラムなので、小数は切り捨てずに入力ごと受け付けない
  def custom_credits(raw_credits)
    value = BigDecimal(raw_credits.to_s, exception: false)
    return unless value&.positive? && value < 100 && value.frac.zero?

    value.to_i
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
    enrollments.any? do |enrollment|
      enrollment.course_id == course.id && BLOCKED_STATUSES.include?(enrollment.enrollment_status)
    end || @student.planned_courses.exists?(course_id: course.id)
  end
end

