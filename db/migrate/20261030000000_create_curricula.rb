# frozen_string_literal: true

# 便覧（卒業要件の文書）をDBに置く。公開済みと、取り込み途中の下書きを同じ表で持つ。
# 本番ではアプリがファイルを書けないため、事務の人が画面から保存した便覧はここに入れる。
class CreateCurricula < ActiveRecord::Migration[8.1]
  def change
    create_table :curricula do |t|
      t.string :slug, null: false
      t.integer :admission_year, null: false
      t.string :faculty_name
      t.string :department_name
      t.string :title
      t.jsonb :document, null: false, default: {}
      t.string :source_filename
      t.jsonb :pages, default: []
      t.datetime :published_at

      t.timestamps
    end

    # 公開済みは同じ slug・年度に1つだけ。下書きは何件あってもよい。
    # 2025年度を読み直している間も、公開済みの2025年度が学生に使われ続けるため。
    add_index :curricula, %i[slug admission_year], unique: true, where: 'published_at IS NOT NULL',
                                                   name: 'index_curricula_on_published_slug_and_year'
  end
end
