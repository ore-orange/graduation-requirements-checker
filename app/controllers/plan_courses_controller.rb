# frozen_string_literal: true

# 履修計画への科目の追加と削除。
class PlanCoursesController < ApplicationController
  include StudentWorkspace

  BLOCKED_STATUSES = %w[completed registered in_progress].freeze

  # 同じ科目番号の Course が複数あり、便覧の科目に当たる行を1つに決められない。
  class AmbiguousCourse < StandardError; end

  # term（"3-後期" など）の学期の予定として追加する。追加できるのは今の学期以降。
  def create
    @term = parse_term(params[:term])
    return back_to_plan(alert: '予定を追加する学期を、今の学期以降から選んでください。') unless @term && term_open?(@term)

    course = selectable_course
    return back_to_plan(alert: '追加できる科目を科目一覧から選択してください。') unless course
    return back_to_plan(alert: 'この科目は修得済み・履修中、または追加済みです。') if unavailable_course?(course)

    @student.planned_courses.create!(course: course, academic_year: term_year(@term), semester: @term[:semester])
    back_to_plan(notice: '今後の履修予定に追加しました。判定を更新しました。')
  rescue AmbiguousCourse
    back_to_plan(alert: '同じ科目番号の科目が複数登録されているため、この科目は追加できません。管理者に確認してください。')
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    back_to_plan(alert: '科目を追加できませんでした。既に追加されていないか確認してください。')
  end

  def destroy
    @term = parse_term(params[:term])
    plan = @student.planned_courses.find_by(id: params[:id])
    return head :not_found unless plan

    course = plan.course
    plan.destroy!
    cleanup_custom_course(course)
    back_to_plan(notice: '今後の履修予定から削除しました。判定を更新しました。')
  end

  private

  # 追加・削除のあとは、見ていた学期の計画表に戻る。
  def back_to_plan(**flash)
    redirect_to plan_path(term: (helpers.term_param(@term) if @term)), status: :see_other, **flash
  end

  def selectable_course
    return build_custom_course if params[:custom_course].present?

    number = params.permit(:course_number)[:course_number]
    find_catalogue_course(number) if number.is_a?(String)
  end

  # 便覧の科目は (科目番号, 科目名) で Course に当たる(科目の作られ方=DemoData・時間割の取り込みと揃える)。
  # 番号だけで探すと、別の入学年度の便覧に同じ番号で名前だけ違う行があるとき(ローマ数字の全角・半角など、
  # 2024年度と2025年度の便覧の知能212のような実例がある)に、今の学生の便覧が指す行をはっきり特定できるのに
  # 「複数ある」と取り違えて追加できなくしてしまう。名前まで一致する行が1つに決まるときはそれを使い、
  # 決まらないとき(名前が便覧のどの行にも一致しない重複など)だけ、どれかを選ばず追加しない。
  def find_catalogue_course(number)
    catalogue_course = @courses_by_number[number]
    return unless catalogue_course && catalogue_course['selectable'] == true

    courses = Course.where(course_number: number, name: catalogue_course.fetch('name')).limit(2).to_a
    raise(DemoAccount::Unavailable, '便覧の科目が登録されていません。bin/rails db:seed を実行してください。') if courses.empty?
    raise AmbiguousCourse if courses.size > 1

    courses.first
  end

  def build_custom_course
    attrs = custom_course_attributes
    return unless attrs

    matched = match_catalogue_course(attrs[:name], attrs[:number])
    return find_catalogue_course(matched.fetch('number')) if matched

    Course.create!(custom_category: attrs[:category], course_number: attrs[:number], name: attrs[:name],
                   credits: attrs[:credits])
  end

  def custom_course_attributes
    raw = params.expect(custom_course: %i[name course_number credits category])
    name = raw[:name].to_s.strip
    category = raw[:category].to_s.strip
    credits = custom_credits(raw[:credits])
    return unless name.present? && custom_categories.include?(category) && credits

    { name: name, number: raw[:course_number].to_s.strip.presence, category: category, credits: credits }
  rescue ActionController::ParameterMissing, ActionController::UnpermittedParameters
    nil
  end

  # 学生が自分で足す科目に選べる区分は、その学年度の便覧が卒業単位に数える区分。
  def custom_categories
    @custom_categories ||= GraduationAssessment::Catalogue.new(@curriculum).counted_category_keys
  end

  # 単位数は整数カラムなので、小数は切り捨てずに入力ごと受け付けない
  def custom_credits(raw_credits)
    value = BigDecimal(raw_credits.to_s, exception: false)
    return unless value&.positive? && value < 100 && value.frac.zero?

    value.to_i
  end

  # 科目番号の無い科目は Course に当てる手がかりが無いので、取り違えないよう突き合わせない。
  def match_catalogue_course(name, number)
    @courses_by_number.each_value.find do |course|
      course['name'].casecmp?(name) || (number.present? && course['number'].to_s.casecmp?(number))
    end
  end

  def cleanup_custom_course(course)
    return unless course.custom?
    return if course.planned_courses.exists? || course.student_courses.exists?

    course.destroy!
  end

  def unavailable_course?(course)
    enrollments.any? do |enrollment|
      enrollment.course_id == course.id && BLOCKED_STATUSES.include?(enrollment.enrollment_status)
    end || @student.planned_courses.exists?(course_id: course.id)
  end
end

