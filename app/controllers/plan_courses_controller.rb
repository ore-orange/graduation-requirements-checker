# frozen_string_literal: true

# 履修計画への科目の追加と削除。
class PlanCoursesController < ApplicationController
  include StudentWorkspace

  BLOCKED_STATUSES = %w[completed registered in_progress].freeze

  # term（"3-後期" など）の学期の予定として追加する。追加できるのは今の学期以降。
  def create
    @term = parse_term(params[:term])
    return back_to_plan(alert: '予定を追加する学期を、今の学期以降から選んでください。') unless @term && term_open?(@term)

    course = selectable_course
    return back_to_plan(alert: '追加できる科目を科目一覧から選択してください。') unless course
    return back_to_plan(alert: 'この科目は修得済み・履修中、または追加済みです。') if unavailable_course?(course)

    @student.planned_courses.create!(course: course, academic_year: term_year(@term), semester: @term[:semester])
    back_to_plan(notice: '今後の履修予定に追加しました。判定を更新しました。')
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

    course_id = params.permit(:course_id)[:course_id]
    find_directory_course(course_id) if course_id.is_a?(String)
  end

  # 「便覧から選択」が送るのは Course の id。同じ番号で名前の違う行があっても、どの行かが決まる。
  # 追加できるのは、名簿にあり、選べる科目だけ。名簿は自由入力の科目と、番号から区分が決まらない科目を載せない。
  def find_directory_course(course_id)
    id = Integer(course_id, 10, exception: false)
    entry = directory.find(id) if id
    return unless entry&.selectable == true

    Course.find_by(id: entry.course_id)
  end

  # 自由入力が便覧の科目と同じ名前・番号のとき、その科目の Course に結びつける。
  # 便覧の名前の行を優先し、無ければ同じ番号の行を使う。Course の行がまだ無ければ、時間割の取り込みが先。
  def matched_directory_course(matched)
    return unless matched['selectable'] == true

    entry = directory_entry_for(matched)
    raise(DemoAccount::Unavailable, '便覧の科目が登録されていません。bin/rails db:seed を実行してください。') unless entry

    find_directory_course(entry.course_id.to_s)
  end

  def directory_entry_for(matched)
    number = matched.fetch('number')
    entries = directory.in_category(directory.category_for(number)).select do |entry|
      entry.number == number && entry.course_id
    end
    entries.find { |entry| entry.name == matched['name'] } || entries.first
  end

  def build_custom_course
    attrs = custom_course_attributes
    return unless attrs

    matched = match_catalogue_course(attrs[:name], attrs[:number])
    return matched_directory_course(matched) if matched

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

