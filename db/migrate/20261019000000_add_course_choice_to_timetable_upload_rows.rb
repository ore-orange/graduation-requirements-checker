# frozen_string_literal: true

# 既存の講義と同じかどうかは、名前や番号で自動判定せず、確認画面で人が選んだ結果を持つ。
# course_id: 既存の講義として扱う / register_as_new: 同じ名前・番号でも別の講義として登録する。
class AddCourseChoiceToTimetableUploadRows < ActiveRecord::Migration[8.1]
  def change
    add_reference :timetable_upload_rows, :course, foreign_key: true
    add_column :timetable_upload_rows, :register_as_new, :boolean, null: false, default: false
  end
end

