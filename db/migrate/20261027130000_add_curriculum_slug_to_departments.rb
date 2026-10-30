# frozen_string_literal: true

# その学科の学生に適用するカリキュラムを指す。config/curricula/<slug>/<入学年度>.json を読む。
#
# カリキュラムを用意していない学科はnullのまま。実際はコース単位で分かれるため、
# programs（未使用）を配線するまでは学科に持たせておく。
# デモ用学科と実在の学科が同じカリキュラムを指すことがあるので、一意にはしない。
class AddCurriculumSlugToDepartments < ActiveRecord::Migration[8.1]
  def change
    add_column :departments, :curriculum_slug, :string
  end
end
