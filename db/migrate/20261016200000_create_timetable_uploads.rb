# frozen_string_literal: true

# PDFから読み取った行を、人が確認し終えるまで置いておく一時テーブル。
# 値はPDFの表記のまま文字列で持ち、courses / course_offerings へは保存時にだけ変換して入れる。
class CreateTimetableUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :timetable_uploads do |t|
      t.string :semester, null: false
      t.string :source_filename
      t.timestamps
    end
    add_check_constraint :timetable_uploads, "semester IN ('前期', '後期')", name: 'timetable_uploads_semester'

    create_table :timetable_upload_rows do |t|
      t.references :timetable_upload, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :lecture_code
      t.string :course_number
      t.string :name
      t.string :credits
      t.string :requirement_type
      t.string :grade_text
      t.string :weekday
      t.string :period_text
      t.string :term_type
      t.text :note
      t.string :review_reason
      t.boolean :confirmed, null: false, default: false
      t.timestamps
    end
    add_index :timetable_upload_rows, %i[timetable_upload_id position], unique: true
  end
end
