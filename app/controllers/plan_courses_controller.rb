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

  # 追加・削除のあとは、見ていた画面（全学期の一覧、または学期の計画表）に戻る。
  # 送ってきたページがわかればその URL にそのまま戻る。今の URL と同じ URL に戻ると、スクロール位置が保たれる。
  def back_to_plan(**flash)
    redirect_to plan_page_sent_from || plan_page_from_params, status: :see_other, **flash
  end

  # フォームを送ってきたページ（ブラウザが Referer として知らせる URL）が計画表なら、そのパスと ? 以降。
  # ホストを捨ててパスだけ使うので、よそのサイトに戻ることはない。
  def plan_page_sent_from
    sent_from = URI.parse(request.referer.to_s)
    sent_from.request_uri if sent_from.path == plan_path
  rescue URI::InvalidURIError
    nil
  end

  # 送ってきたページがわからないときは、フォームの項目から戻る先を組み立てる。
  def plan_page_from_params
    return plan_path(view: 'all') if params[:view] == 'all'

    plan_path(term: (helpers.term_param(@term) if @term), **catalogue_pane_params)
  end

  # 便覧のパネルを開いていたら（pane=catalogue）、戻ったあとも開いたままにして、検索語（q）も残す。
  def catalogue_pane_params
    pane, query = params.permit(:pane, :q).values_at(:pane, :q)
    pane == 'catalogue' ? { pane: pane, q: query.presence }.compact : {}
  end

  def selectable_course
    key = params.permit(:course_key)[:course_key]
    find_catalogue_course(key) if key.is_a?(String)
  end

  def find_catalogue_course(key)
    catalogue_course = @courses_by_key[key]
    return unless catalogue_course && catalogue_course['selectable'] == true

    Course.find_by(curriculum_key: key) ||
      raise(SetupIncomplete, 'カリキュラムの科目が登録されていません。')
  end

  # 自由入力の科目は以前に追加された予定だけが残っている。その最後の予定を消したら科目も消す
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

