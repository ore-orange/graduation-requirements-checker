# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_27_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "courses", force: :cascade do |t|
    t.string "course_number"
    t.string "name", null: false
    t.decimal "credits", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "curriculum_key"
    t.index ["course_number"], name: "index_courses_on_course_number"
    t.index ["curriculum_key"], name: "index_courses_on_curriculum_key", unique: true, where: "(curriculum_key IS NOT NULL)"
    t.check_constraint "credits >= 0::numeric", name: "courses_nonnegative_credits"
  end

  create_table "departments", force: :cascade do |t|
    t.bigint "faculty_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["faculty_id"], name: "index_departments_on_faculty_id"
  end

  create_table "faculties", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "planned_courses", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "course_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "academic_year", null: false
    t.string "semester", null: false
    t.index ["course_id"], name: "index_planned_courses_on_course_id"
    t.index ["student_id", "course_id"], name: "index_planned_courses_on_student_id_and_course_id", unique: true
    t.index ["student_id"], name: "index_planned_courses_on_student_id"
    t.check_constraint "academic_year >= 1 AND academic_year <= 9999", name: "planned_courses_year_range"
    t.check_constraint "semester::text = ANY (ARRAY['前期'::character varying, '後期'::character varying]::text[])", name: "planned_courses_semester"
  end

  create_table "programs", force: :cascade do |t|
    t.bigint "department_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["department_id"], name: "index_programs_on_department_id"
  end

  create_table "student_courses", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "course_id", null: false
    t.integer "academic_year", null: false
    t.string "semester"
    t.string "grade"
    t.decimal "credits_earned", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "enrollment_status", default: "unknown", null: false
    t.boolean "approval_confirmed"
    t.index ["course_id"], name: "index_student_courses_on_course_id"
    t.index ["student_id", "academic_year"], name: "index_student_courses_on_student_id_and_academic_year"
    t.index ["student_id"], name: "index_student_courses_on_student_id"
    t.check_constraint "academic_year >= 1 AND academic_year <= 9999", name: "student_courses_year_range"
    t.check_constraint "credits_earned >= 0::numeric", name: "student_courses_nonnegative_credits"
    t.check_constraint "enrollment_status::text = ANY (ARRAY['completed'::character varying, 'registered'::character varying, 'in_progress'::character varying, 'failed'::character varying, 'unknown'::character varying]::text[])", name: "student_courses_enrollment_status"
  end

  create_table "student_program_assignments", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "program_id", null: false
    t.string "status", null: false
    t.datetime "assigned_at"
    t.datetime "ended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["program_id"], name: "index_student_program_assignments_on_program_id"
    t.index ["student_id", "assigned_at"], name: "idx_on_student_id_assigned_at_63a6b616de"
    t.index ["student_id"], name: "index_student_program_assignments_on_student_id"
    t.check_constraint "ended_at IS NULL OR assigned_at IS NOT NULL AND ended_at >= assigned_at", name: "student_program_assignments_chronology"
  end

  create_table "students", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "admission_year", null: false
    t.bigint "department_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["department_id", "admission_year"], name: "index_students_on_department_id_and_admission_year"
    t.index ["department_id"], name: "index_students_on_department_id"
    t.index ["user_id"], name: "index_students_on_user_id", unique: true
    t.check_constraint "admission_year >= 1 AND admission_year <= 9999", name: "students_admission_year_range"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
  end

  add_foreign_key "departments", "faculties"
  add_foreign_key "planned_courses", "courses"
  add_foreign_key "planned_courses", "students"
  add_foreign_key "programs", "departments"
  add_foreign_key "student_courses", "courses"
  add_foreign_key "student_courses", "students"
  add_foreign_key "student_program_assignments", "programs"
  add_foreign_key "student_program_assignments", "students"
  add_foreign_key "students", "departments"
  add_foreign_key "students", "users"
end
