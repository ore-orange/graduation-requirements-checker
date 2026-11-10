# frozen_string_literal: true

# 学生の所属を学科からコースへ移す。
# 卒業要件は実際にはコース単位で分かれるため、学科に持たせていた参照をコースへ移す。
#
# 既存の学生が居る学科には、その学科の名前とカリキュラムをそのまま引き写したコースを
# 1つ作り、学生をそこへ繋ぎ替える。学生の居ない学科にはコースを作らない（実在の
# コースは別途マスタから入れるため、ここで名前だけの行を増やさない）。
# モデルクラスを使わないのは、将来モデルを変えてもこのマイグレーションが
# 動き続けるようにするため。
class AddProgramToStudents < ActiveRecord::Migration[8.1]
  def up
    add_reference :students, :program, foreign_key: true
    add_index :students, %i[program_id admission_year]

    copy_departments_into_programs
    adopt_curriculum_from_departments
    execute(<<~SQL.squish)
      UPDATE students
      SET program_id = (SELECT MIN(programs.id) FROM programs
                        WHERE programs.department_id = students.department_id)
    SQL

    change_column_null :students, :program_id, false
    remove_reference :students, :department, foreign_key: true
  end

  def down
    return_curriculum_to_departments
    add_reference :students, :department, foreign_key: true
    add_index :students, %i[department_id admission_year]

    execute(<<~SQL.squish)
      UPDATE students
      SET department_id = (SELECT programs.department_id FROM programs
                           WHERE programs.id = students.program_id)
    SQL

    change_column_null :students, :department_id, false
    remove_reference :students, :program, foreign_key: true
  end

  private

  # 巻き戻してから進め直したときのために、既にあるコースにも学科のカリキュラムを引き写す。
  # 新しく作った行だけを埋める作りにすると、往復でカリキュラムの参照が失われる。
  def adopt_curriculum_from_departments
    execute(<<~SQL.squish)
      UPDATE programs
      SET curriculum_slug = departments.curriculum_slug
      FROM departments
      WHERE departments.id = programs.department_id
        AND programs.curriculum_slug IS NULL
        AND departments.curriculum_slug IS NOT NULL
    SQL
  end

  # programs.curriculum_slug は次の巻き戻しで列ごと消えるため、学科へ書き戻しておく。
  def return_curriculum_to_departments
    execute(<<~SQL.squish)
      UPDATE departments
      SET curriculum_slug = programs.curriculum_slug
      FROM programs
      WHERE programs.department_id = departments.id
        AND programs.curriculum_slug IS NOT NULL
    SQL
  end

  def copy_departments_into_programs
    execute(<<~SQL.squish)
      INSERT INTO programs (department_id, name, curriculum_slug, created_at, updated_at)
      SELECT departments.id, departments.name, departments.curriculum_slug, NOW(), NOW()
      FROM departments
      WHERE EXISTS (SELECT 1 FROM students WHERE students.department_id = departments.id)
        AND NOT EXISTS (SELECT 1 FROM programs WHERE programs.department_id = departments.id)
    SQL
  end
end
