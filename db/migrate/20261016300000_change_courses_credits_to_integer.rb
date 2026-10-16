# frozen_string_literal: true

# 科目の単位は整数で管理する。小数が入っているデータがあれば、丸めずに中止する。
class ChangeCoursesCreditsToInteger < ActiveRecord::Migration[8.1]
  def up
    if select_value('SELECT 1 FROM courses WHERE credits <> trunc(credits) LIMIT 1')
      raise ActiveRecord::IrreversibleMigration, 'courses.credits に小数があるため、整数に変換できません。'
    end

    change_column :courses, :credits, :integer, using: 'credits::integer'
  end

  def down
    change_column :courses, :credits, :decimal, precision: 5, scale: 2
  end
end

