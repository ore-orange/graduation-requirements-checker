# frozen_string_literal: true

# 初回ログイン後に、コースと入学年度を登録する。
class StudentsController < ApplicationController
  before_action :redirect_if_registered, only: %i[new create]

  def new
    @student = Current.user.build_student
    load_programs
  end

  def create
    @student = Current.user.build_student(student_params)
    return redirect_to root_path, notice: '学籍情報を登録しました。' if @student.save

    load_programs
    render :new, status: :unprocessable_content
  end

  private

  def redirect_if_registered
    redirect_to root_path if Current.user.student.present?
  end

  def load_programs
    @programs = Program.selectable.to_a
  end

  def student_params
    params.expect(student: %i[program_id admission_year])
  end
end

