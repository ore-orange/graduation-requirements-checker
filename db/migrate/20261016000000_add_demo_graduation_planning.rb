# frozen_string_literal: true

class AddDemoGraduationPlanning < ActiveRecord::Migration[8.1]
  def change
    add_column :courses, :curriculum_key, :string
    add_index :courses, :curriculum_key, unique: true, where: 'curriculum_key IS NOT NULL'

    add_column :student_courses, :enrollment_status, :string, null: false, default: 'unknown'
    add_column :student_courses, :approval_confirmed, :boolean
    add_check_constraint :student_courses,
                         "enrollment_status IN ('completed', 'registered', 'in_progress', 'failed', 'unknown')",
                         name: 'student_courses_enrollment_status'

    create_table :planned_courses do |t|
      t.references :student, null: false, foreign_key: true
      t.references :course, null: false, foreign_key: true
      t.timestamps
    end
    add_index :planned_courses, %i[student_id course_id], unique: true
  end
end
