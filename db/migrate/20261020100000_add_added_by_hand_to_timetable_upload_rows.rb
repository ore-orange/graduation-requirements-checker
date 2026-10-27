# frozen_string_literal: true

class AddAddedByHandToTimetableUploadRows < ActiveRecord::Migration[8.1]
  def change
    add_column :timetable_upload_rows, :added_by_hand, :boolean, default: false, null: false
  end
end
