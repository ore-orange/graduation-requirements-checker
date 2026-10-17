# frozen_string_literal: true

class CreateGraduationCheckerTables < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.timestamps
    end
    add_index :users, 'lower(email)', unique: true, name: 'index_users_on_lower_email'

    create_table :faculties do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :departments do |t|
      t.references :faculty, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end

    create_table :programs do |t|
      t.references :department, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end

    create_table :students do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.integer :admission_year, null: false
      t.references :department, null: false, foreign_key: true
      t.timestamps
    end
    add_index :students, %i[department_id admission_year]
    add_check_constraint :students, 'admission_year BETWEEN 1 AND 9999', name: 'students_admission_year_range'

    create_table :courses do |t|
      # 番号は同一性の根拠ではなく、検索用の代表番号。未確認の場合はNULL。
      t.string :course_number
      t.string :name, null: false
      t.decimal :credits, precision: 5, scale: 2
      t.timestamps
    end
    add_index :courses, :course_number
    add_check_constraint :courses, 'credits >= 0', name: 'courses_nonnegative_credits'

    create_table :student_courses do |t|
      t.references :student, null: false, foreign_key: true
      t.references :course, null: false, foreign_key: true
      t.integer :academic_year, null: false
      t.string :semester
      t.string :grade
      # NULLは未確定、0は修得単位なし。マスタの単位数から自動補完しない。
      t.decimal :credits_earned, precision: 5, scale: 2
      t.timestamps
    end
    # 再履修・複数開講を許容し、student/course/year/semesterにも一意制約は付けない。
    add_index :student_courses, %i[student_id academic_year]
    add_check_constraint :student_courses, 'academic_year BETWEEN 1 AND 9999', name: 'student_courses_year_range'
    add_check_constraint :student_courses, 'credits_earned >= 0', name: 'student_courses_nonnegative_credits'

    create_table :student_program_assignments do |t|
      t.references :student, null: false, foreign_key: true
      t.references :program, null: false, foreign_key: true
      t.string :status, null: false
      t.datetime :assigned_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :student_program_assignments, %i[student_id assigned_at]
    add_check_constraint :student_program_assignments,
                         'ended_at IS NULL OR (assigned_at IS NOT NULL AND ended_at >= assigned_at)',
                         name: 'student_program_assignments_chronology'
  end
end
