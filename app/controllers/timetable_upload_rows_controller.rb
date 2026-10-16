# frozen_string_literal: true

class TimetableUploadRowsController < ApplicationController
  include LocalAccessOnly

  def update
    upload = TimetableUpload.find(params.expect(:timetable_upload_id))
    row = upload.rows.find(params.expect(:id))
    row.assign_attributes(row_params.transform_values { |value| value.to_s.strip })
    problems = confirm_if_valid(row)
    row.save!

    label = "#{row.position + 1}行目"
    if problems.empty?
      redirect_to timetable_upload_path(upload, page: params[:page].presence), notice: "#{label}を更新しました。",
                                                                               status: :see_other
    else
      redirect_to timetable_upload_path(upload, page: params[:page].presence),
                  alert: "#{label}は確認済みにできません: #{problems.join(' ')}", status: :see_other
    end
  end

  private

  # 値を直したら確認し直してもらう。確認済みにできるのは、値がDBに入れられる形のときだけ。
  def confirm_if_valid(row)
    row.confirmed = params[:confirmed] == '1'
    problems = row.confirmed ? row.problems : []
    row.confirmed = false if problems.any?
    problems
  end

  def row_params
    params.expect(row: TimetableUploadRow::EDITABLE)
  end
end

