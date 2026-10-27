# frozen_string_literal: true

class CreateCourseOfferings < ActiveRecord::Migration[8.1]
  def change
    create_table :course_offerings do |t|
      t.references :course, null: false, foreign_key: true
      t.string :semester, null: false
      t.string :lecture_code
      t.string :requirement_type
      t.integer :grade_years, array: true, null: false, default: []
      t.string :weekday
      t.integer :periods, array: true, null: false, default: []
      t.string :term_type
      t.timestamps
    end

    add_index :course_offerings, %i[semester lecture_code], unique: true, where: 'lecture_code IS NOT NULL'
    add_check_constraint :course_offerings, "semester IN ('前期', '後期')", name: 'course_offerings_semester'
    add_check_constraint :course_offerings,
                         "requirement_type IS NULL OR requirement_type IN ('必修', '選択')",
                         name: 'course_offerings_requirement_type'
  end
end
