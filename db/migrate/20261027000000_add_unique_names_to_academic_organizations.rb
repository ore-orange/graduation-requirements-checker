# frozen_string_literal: true

# 学部・学科は選択肢の元になるマスタなので、名前の重複を許さない。
# 重複を許すと、seedで名前を直したときに既存の行が改名されず2つめの行ができ、
# 講義が古い行を指したまま残って、同じ学部で絞り込めなくなる。
class AddUniqueNamesToAcademicOrganizations < ActiveRecord::Migration[8.1]
  def up
    if select_value('SELECT 1 FROM faculties GROUP BY name HAVING count(*) > 1 LIMIT 1')
      raise ActiveRecord::IrreversibleMigration, 'faculties に同じ名前の学部があるため、一意にできません。'
    end
    if select_value('SELECT 1 FROM departments GROUP BY faculty_id, name HAVING count(*) > 1 LIMIT 1')
      raise ActiveRecord::IrreversibleMigration, 'departments に同じ学部・同じ名前の学科があるため、一意にできません。'
    end

    add_index :faculties, :name, unique: true
    add_index :departments, %i[faculty_id name], unique: true
  end

  def down
    remove_index :departments, %i[faculty_id name]
    remove_index :faculties, :name
  end
end
