# frozen_string_literal: true

# 便覧(卒業要件の文書)をDBに置く。これまでは config/curricula のJSONをアプリが直接読んでいた。
# 本番ではアプリがファイルを書けないため、管理者が画面から登録する便覧の置き場としてDBに移す。
class CreateCurricula < ActiveRecord::Migration[8.1]
  def change
    create_table :curricula do |t|
      t.string :slug, null: false
      t.integer :admission_year, null: false
      t.string :title
      t.jsonb :document, null: false, default: {}
      t.datetime :published_at

      t.timestamps
    end

    # 学生の判定に使う公開済みは、同じ slug・入学年度に1つだけ。
    # 公開していない行(あとで作る取り込み途中の下書き)は何件あってもよい。
    add_index :curricula, %i[slug admission_year], unique: true, where: 'published_at IS NOT NULL',
                                                   name: 'index_curricula_on_published_slug_and_year'
  end
end

