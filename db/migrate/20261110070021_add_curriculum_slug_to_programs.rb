# frozen_string_literal: true

# どのカリキュラムを適用するかはコース単位で決まる。config/curricula/<slug>/<入学年度>.json を読む。
# カリキュラムを用意していないコースはnullのまま。
# デモ用コースと実在のコースが同じカリキュラムを指すことがあるので、slugは一意にしない。
# 同じ学科に同名のコースが2つできるのは誤りなので、そちらは一意にする。
class AddCurriculumSlugToPrograms < ActiveRecord::Migration[8.1]
  def change
    add_column :programs, :curriculum_slug, :string
    add_index :programs, %i[department_id name], unique: true
  end
end
