# frozen_string_literal: true

# Googleアカウントでログインできるようにする。
# google_uid は Google が払い出す不変のID。メールアドレスは本人が変更できるため、
# アカウントの同一性はこちらで見る。パスワードだけの利用者も残すので nullable。
#
# Googleだけで入る利用者はパスワードを持たないため、password_digest の NOT NULL を外す。
# どちらも持たない行が生まれないことは User 側のバリデーションで担保する。
class AddGoogleUidToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :google_uid, :string
    add_index :users, :google_uid, unique: true
    change_column_null :users, :password_digest, true
  end
end
