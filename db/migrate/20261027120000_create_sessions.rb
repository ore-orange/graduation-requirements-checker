# frozen_string_literal: true

# ログイン状態はDBのセッション行で持つ。Cookieには署名付きのidだけを入れる。
# 接続元を残しておくと、身に覚えのないログインに気づける。
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end
  end
end
