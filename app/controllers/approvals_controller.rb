# frozen_string_literal: true

# 指導教員の承認が要る科目について、学生自身が「承認を得たか」に答える。便覧(courses)は承認が要ることまでしか
# 言えず、実際に得たかどうかは学生側の事実なので、それをここで確定させる。答えるまでは nil のまま残し、
# 見込み判定は要確認のままにする（EntryNormalizer が nil・複数不一致を要確認、false を算入対象外にする）。
class ApprovalsController < ApplicationController
  include StudentWorkspace

  # kind は対象のテーブルを表す。履修計画(planned_courses)と、修得済み・履修中の記録(student_courses)の
  # どちらも承認待ちになり得るので、両方を受け付ける。
  ASSOCIATIONS = { 'plan' => :planned_courses, 'enrollment' => :student_courses }.freeze

  def update
    record = find_record
    return head :not_found unless record
    # 承認が要らない科目の回答は、判定では使われず保存するだけ無意味なので受け付けない(誤操作・不正な送信の防止)。
    return head :unprocessable_content unless requires_approval?(record.course)

    record.update!(approval_confirmed: approved_param)
    @term = parse_term(params[:term]) || current_term

    respond_to do |format|
      format.turbo_stream { render turbo_stream: replace_stream(record) }
      format.html { redirect_to plan_path(term: helpers.term_param(@term)), status: :see_other }
    end
  end

  private

  # 自分（@student）の記録だけを対象にする。他の学生の記録は find_by の対象外になり 404 になる。
  def find_record
    association = ASSOCIATIONS[params[:kind]]
    @student.public_send(association).find_by(id: params[:id]) if association
  end

  def requires_approval?(course)
    @courses_by_number[course.course_number]&.fetch('requires_approval', false) == true
  end

  # 'true'/'false' の文字列だけを答えとして受け取る。それ以外（空・未指定）は「未回答」に戻すための nil。
  def approved_param
    case params[:approved]
    when 'true' then true
    when 'false' then false
    end
  end

  # 保存した1行だけを差し替える。画面全体を作り直さないので、スクロール位置や他の行の状態はそのまま。
  def replace_stream(record)
    if record.is_a?(PlannedCourse)
      turbo_stream.replace("plan_#{record.id}", partial: 'plans/plan_card', locals: { plan: record })
    else
      turbo_stream.replace("enrollment_#{record.id}", partial: 'plans/enrollment_card', locals: { enrollment: record })
    end
  end
end

