# frozen_string_literal: true

# 科目と便覧の対応を、保存したキーから「入学年度で便覧を選び、科目番号でその中の科目を選ぶ」導出に替える。
# courses.curriculum_key はDB全体で一意なので、同じ「工共100 工学基礎演習」が年度ごとの便覧に載ると、1行の Course に
# 2つのキーを持たせることになる。キーを持つのをやめれば、年度が増えても Course は増えない。
#
# あわせて、このあと使う列をここで足しておく。
# - courses.custom_category: 自由入力計画科目の区分。これまで curriculum_key の 'custom:<区分>:<乱数>' に埋め込んでいた。
# - students.curriculum_id: 学生が判定に使う便覧。公開済みであることはモデルで検める。
# - planned_courses.approval_confirmed: 履修予定の承認確認。使うのはあとの変更だが、スキーマを一度で済ませる。
class ReplaceCurriculumKeyWithNumberLookup < ActiveRecord::Migration[8.1]
  def up
    add_column :courses, :custom_category, :string
    # 列を落とす前に、文字列に埋め込まれていた区分を取り出す。
    execute <<~SQL.squish
      UPDATE courses SET custom_category = split_part(curriculum_key, ':', 2)
      WHERE curriculum_key LIKE 'custom:%'
    SQL

    remove_index :courses, :curriculum_key, unique: true, where: 'curriculum_key IS NOT NULL'
    remove_column :courses, :curriculum_key

    # 既存の学生には便覧を割り当てない。どの便覧が正しいかは入学年度だけでは決まらないので、
    # 割り当てるまでは設定画面になる（判定しない側に倒す）。デモ学生は db:seed が割り当てる。
    add_reference :students, :curriculum, foreign_key: true, null: true
    add_column :planned_courses, :approval_confirmed, :boolean
  end

  # 便覧の科目に付いていたキーは科目番号から導けるものではなく、戻せない。自由入力の科目だけ、区分を埋めた
  # キーを作り直す。便覧の科目は DemoData を流し直すと、番号と名前で引き当てたうえで作られる（キーは付かない）。
  def down
    remove_column :planned_courses, :approval_confirmed
    remove_reference :students, :curriculum, foreign_key: true

    add_column :courses, :curriculum_key, :string
    add_index :courses, :curriculum_key, unique: true, where: 'curriculum_key IS NOT NULL'
    execute <<~SQL.squish
      UPDATE courses SET curriculum_key = 'custom:' || custom_category || ':' || substr(md5(id::text), 1, 12)
      WHERE custom_category IS NOT NULL AND custom_category <> ''
    SQL
    remove_column :courses, :custom_category
  end
end
