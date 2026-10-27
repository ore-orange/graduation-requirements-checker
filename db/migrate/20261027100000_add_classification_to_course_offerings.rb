# frozen_string_literal: true

# 講義に開講年度と開講学科を持たせ、講義コードを必須にする。
#
# 年度・学科をNULL可にしているのは、courses と course_offerings を1つにまとめるとき(#53)に、
# curriculum_key から作った科目(年度も学科も持たない)が同じテーブルに同居するため。
# 取り込みの画面では年度・学科を必須にするので、PDFから入った講義に空はできない。
#
# このテーブルは main には無く、入っているのは開発中のデータだけなので、
# 講義コードを必須にする前に既存の行を消す。
class AddClassificationToCourseOfferings < ActiveRecord::Migration[8.1]
  def up
    delete_existing_imports

    add_column :course_offerings, :year, :integer
    add_reference :course_offerings, :department, foreign_key: true
    change_column_null :course_offerings, :lecture_code, false

    remove_index :course_offerings, %i[semester lecture_code]
    add_index :course_offerings, %i[year semester lecture_code], unique: true
    add_check_constraint :course_offerings, 'year IS NULL OR (year >= 1 AND year <= 9999)',
                         name: 'course_offerings_year_range'

    add_column :timetable_uploads, :year, :integer, null: false
    add_reference :timetable_uploads, :department, null: false, foreign_key: true
    add_check_constraint :timetable_uploads, 'year >= 1 AND year <= 9999', name: 'timetable_uploads_year_range'
  end

  def down
    # 年度をまたいで同じ講義コードを登録できるのがこの変更の目的なので、戻すと
    # 古い「学期＋講義コード」の一意制約に引っかかる行が残りうる。
    # PG::UniqueViolation を素で出すより、理由を出して止める。
    if select_value('SELECT 1 FROM course_offerings LIMIT 1')
      raise ActiveRecord::IrreversibleMigration,
            'course_offerings に行があるため戻せません。年度が違う同じ講義コードは、' \
            '戻したあとの「学期＋講義コード」の一意制約を満たせません。' \
            '戻す場合は course_offerings の行を消してから実行してください。'
    end

    remove_check_constraint :timetable_uploads, name: 'timetable_uploads_year_range'
    remove_reference :timetable_uploads, :department, foreign_key: true
    remove_column :timetable_uploads, :year

    remove_check_constraint :course_offerings, name: 'course_offerings_year_range'
    remove_index :course_offerings, %i[year semester lecture_code]
    add_index :course_offerings, %i[semester lecture_code], unique: true, where: 'lecture_code IS NOT NULL'

    change_column_null :course_offerings, :lecture_code, true
    remove_reference :course_offerings, :department, foreign_key: true
    remove_column :course_offerings, :year
  end

  private

  # 取り込み済みのデータを消す。確認待ちの取り込み → 開講情報 → 取り込みが作った科目の順。
  # 科目は、curriculum_key を持つもの(DemoDataが作り、履修履歴・履修計画から参照される)を残す。
  def delete_existing_imports
    execute 'DELETE FROM timetable_upload_rows'
    execute 'DELETE FROM timetable_uploads'
    execute 'DELETE FROM course_offerings'
    execute <<~SQL.squish
      DELETE FROM courses
       WHERE curriculum_key IS NULL
         AND id NOT IN (SELECT course_id FROM student_courses)
         AND id NOT IN (SELECT course_id FROM planned_courses)
    SQL

    kept = select_value('SELECT count(*) FROM courses WHERE curriculum_key IS NULL').to_i
    return if kept.zero?

    say "履修履歴・履修計画から参照されているため、取り込みが作った科目#{kept}件を残しました。" \
        '取り込み直すときは、その科目を「既存の講義として扱う」で選ぶ必要があります。'
  end
end
