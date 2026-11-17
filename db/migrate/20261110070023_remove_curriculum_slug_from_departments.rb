# frozen_string_literal: true

# カリキュラムの参照先はコースへ移した。二重に持たないよう学科からは消す。
class RemoveCurriculumSlugFromDepartments < ActiveRecord::Migration[8.1]
  def change
    remove_column :departments, :curriculum_slug, :string
  end
end
