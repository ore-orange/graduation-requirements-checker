# frozen_string_literal: true

# courses と course_offerings を1つの表にまとめる(#53)。
#
# 統合後の courses に入るのは次の2種類だけで、courses_offering_pair がそれを示す。
#   - 便覧(カリキュラムJSON)由来の科目: curriculum_key を持ち、開講の列は空
#   - 授業時間配当表の開講1件: (年度, 学期, 講義コード)で一意
#
# 講義の同一性が(年度, 学期, 講義コード)だけで決まるので、取り込みのときに
# 「既存の科目に紐づけるか、新しい科目として登録するか」を人に選ばせる必要がなくなる。
# その選択を持っていた timetable_upload_rows の列も、ここで一緒に落とす。
class MergeCourseOfferingsIntoCourses < ActiveRecord::Migration[8.1]
  def up
    drop_course_choice
    add_offering_columns
    move_offerings
    delete_unused_courses
    add_offering_constraints
    drop_table :course_offerings
  end

  def down
    create_course_offerings
    restore_offerings
    add_course_offerings_constraints
    remove_offering_columns
    restore_course_choice
    say '開講1件につき科目1行として戻しました。統合前の「1科目に複数学期の開講」というまとまりは' \
        '復元できないため、同じ科目が学期ごとに別の行になっています。'
  end

  private

  # 取り込み行が持っていた「既存の講義として扱う/別の講義として登録」の選択。
  # 確認中の取り込みを続けられるよう、行そのものは消さない(PDFから読んだ値と確認済みのチェックは残る)。
  def drop_course_choice
    remove_reference :timetable_upload_rows, :course, foreign_key: true
    remove_column :timetable_upload_rows, :register_as_new
  end

  # 便覧由来の行はこれらをすべて空にするので、どれもNULL可にする。
  # 取り込みの画面では年度・学科を必須で選ばせるため、PDFから入った行が空になることはない。
  def add_offering_columns
    add_column :courses, :year, :integer
    add_column :courses, :semester, :string
    add_column :courses, :lecture_code, :string
    add_column :courses, :requirement_type, :string
    add_column :courses, :grade_years, :integer, array: true, null: false, default: []
    add_column :courses, :weekday, :string
    add_column :courses, :periods, :integer, array: true, null: false, default: []
    add_column :courses, :term_type, :string
    add_reference :courses, :department, foreign_key: true
  end

  def move_offerings
    update_first_offerings
    insert_remaining_offerings
  end

  # その科目の最初の開講行で、科目行が curriculum_key を持たないもの → その場で更新する。
  # id が変わらないので student_courses / planned_courses の参照が切れない。
  def update_first_offerings
    execute <<~SQL.squish
      UPDATE courses c
         SET year = o.year, semester = o.semester, lecture_code = o.lecture_code,
             requirement_type = o.requirement_type, grade_years = o.grade_years,
             weekday = o.weekday, periods = o.periods, term_type = o.term_type,
             department_id = o.department_id, updated_at = o.updated_at
        FROM (SELECT DISTINCT ON (course_id) * FROM course_offerings ORDER BY course_id, id) o
       WHERE c.id = o.course_id
         AND c.curriculum_key IS NULL
    SQL
  end

  # 残り(2件目以降の開講、または科目行が curriculum_key を持つもの) → 新しい行にする。
  # curriculum_key はコピーしない。コピーすると一意indexに当たって移行が途中で死ぬうえ、
  # 便覧の科目行に開講情報が載ると、同じ科目を学期ごとに持てなくなる。
  def insert_remaining_offerings
    execute <<~SQL.squish
      INSERT INTO courses (course_number, name, credits, year, semester, lecture_code,
                           requirement_type, grade_years, weekday, periods, term_type,
                           department_id, created_at, updated_at)
      SELECT c.course_number, c.name, c.credits, o.year, o.semester, o.lecture_code,
             o.requirement_type, o.grade_years, o.weekday, o.periods, o.term_type,
             o.department_id, o.created_at, o.updated_at
        FROM course_offerings o
        JOIN courses c ON c.id = o.course_id
       WHERE c.curriculum_key IS NOT NULL
          OR o.id <> (SELECT min(id) FROM course_offerings WHERE course_id = o.course_id)
    SQL
  end

  # 開講情報を移したあとに残る、便覧でも開講でもない科目行を消す。
  # 履修履歴・履修計画から参照されている行は、消すと参照が切れるので残す。
  def delete_unused_courses
    execute <<~SQL.squish
      DELETE FROM courses
       WHERE curriculum_key IS NULL
         AND lecture_code IS NULL
         AND id NOT IN (SELECT course_id FROM student_courses)
         AND id NOT IN (SELECT course_id FROM planned_courses)
    SQL

    kept = select_value(<<~SQL.squish).to_i
      SELECT count(*) FROM courses WHERE curriculum_key IS NULL AND lecture_code IS NULL
    SQL
    return if kept.zero?

    say "履修履歴・履修計画から参照されているため、開講情報を持たない科目#{kept}件を残しました。"
  end

  # データを直したあとに付ける。移行漏れがあればここで止まる。
  def add_offering_constraints
    add_index :courses, %i[year semester lecture_code], unique: true,
                                                        where: 'lecture_code IS NOT NULL'
    add_check_constraint :courses,
                         '(lecture_code IS NULL AND semester IS NULL) OR ' \
                         '(lecture_code IS NOT NULL AND semester IS NOT NULL)',
                         name: 'courses_offering_pair'
    add_check_constraint :courses, "semester IS NULL OR semester IN ('前期', '後期')",
                         name: 'courses_semester'
    add_check_constraint :courses,
                         "requirement_type IS NULL OR requirement_type IN ('必修', '選択')",
                         name: 'courses_requirement_type'
    add_check_constraint :courses, 'year IS NULL OR (year >= 1 AND year <= 9999)',
                         name: 'courses_year_range'
  end

  def create_course_offerings
    create_table :course_offerings do |t|
      t.references :course, null: false, foreign_key: true
      t.string :semester, null: false
      t.string :lecture_code, null: false
      t.string :requirement_type
      t.integer :grade_years, array: true, null: false, default: []
      t.string :weekday
      t.integer :periods, array: true, null: false, default: []
      t.string :term_type
      t.integer :year
      t.timestamps
    end
    add_reference :course_offerings, :department, foreign_key: true
  end

  def restore_offerings
    execute <<~SQL.squish
      INSERT INTO course_offerings (course_id, semester, lecture_code, requirement_type,
                                    grade_years, weekday, periods, term_type, year,
                                    department_id, created_at, updated_at)
      SELECT id, semester, lecture_code, requirement_type, grade_years, weekday, periods,
             term_type, year, department_id, created_at, updated_at
        FROM courses
       WHERE lecture_code IS NOT NULL
    SQL
  end

  def add_course_offerings_constraints
    add_index :course_offerings, %i[year semester lecture_code], unique: true
    add_check_constraint :course_offerings, "semester IN ('前期', '後期')",
                         name: 'course_offerings_semester'
    add_check_constraint :course_offerings,
                         "requirement_type IS NULL OR requirement_type IN ('必修', '選択')",
                         name: 'course_offerings_requirement_type'
    add_check_constraint :course_offerings, 'year IS NULL OR (year >= 1 AND year <= 9999)',
                         name: 'course_offerings_year_range'
  end

  def remove_offering_columns
    remove_check_constraint :courses, name: 'courses_year_range'
    remove_check_constraint :courses, name: 'courses_requirement_type'
    remove_check_constraint :courses, name: 'courses_semester'
    remove_check_constraint :courses, name: 'courses_offering_pair'
    remove_index :courses, %i[year semester lecture_code]
    remove_reference :courses, :department, foreign_key: true
    %i[term_type periods weekday grade_years requirement_type lecture_code semester year].each do |column|
      remove_column :courses, column
    end
  end

  # 値は復元できないので既定値で戻す。
  def restore_course_choice
    add_reference :timetable_upload_rows, :course, foreign_key: true
    add_column :timetable_upload_rows, :register_as_new, :boolean, null: false, default: false
  end
end

