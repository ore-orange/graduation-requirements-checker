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

  # キーは科目番号から導けるものではないが、公開済みの便覧の文書が number と key の対を全部持っているので、そこから戻す。
  # 戻せないまま列だけ戻すと、キーの無い行が残り、旧 DemoData がキー付きの行をもう1つ作って、デモの学生が同じ科目を
  # 二重に履修してしまう。公開済みの便覧が無ければ、中途半端に戻さず拒む。
  # 年度の古い便覧の key を優先し、同じ番号の行が複数あれば最初の1行にだけ付ける（一意索引のため）。
  def down
    keys = handbook_keys_by_number
    raise ActiveRecord::IrreversibleMigration, '公開済みの便覧が無いため、courses.curriculum_key を戻せません。' if keys.empty?

    remove_column :planned_courses, :approval_confirmed
    remove_reference :students, :curriculum, foreign_key: true

    add_column :courses, :curriculum_key, :string
    add_index :courses, :curriculum_key, unique: true, where: 'curriculum_key IS NOT NULL'
    execute <<~SQL.squish
      UPDATE courses SET curriculum_key = 'custom:' || custom_category || ':' || substr(md5(id::text), 1, 12)
      WHERE custom_category IS NOT NULL AND custom_category <> ''
    SQL
    keys.each do |number, key|
      execute <<~SQL.squish
        UPDATE courses SET curriculum_key = #{quote(key)}
        WHERE id = (SELECT min(id) FROM courses WHERE course_number = #{quote(number)} AND curriculum_key IS NULL)
      SQL
    end
    remove_column :courses, :custom_category
  end

  private

  def handbook_keys_by_number
    used = {}
    select_values('SELECT document::text FROM curricula WHERE published_at IS NOT NULL ORDER BY admission_year, id')
      .each_with_object({}) do |json, keys|
      JSON.parse(json).fetch('courses', []).each do |course|
        number = course['number']
        key = course['key']
        next if number.blank? || key.blank? || keys.key?(number) || used.key?(key)

        keys[number] = key
        used[key] = true
      end
    end
  end
end

