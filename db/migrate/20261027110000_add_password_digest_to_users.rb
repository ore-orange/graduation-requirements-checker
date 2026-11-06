# frozen_string_literal: true

# メールアドレスとパスワードでログインできるようにする。
# 既存の行（デモ用ユーザー）はパスワードを持たないため、
# いきなり null: false にはできない。誰も知りえないダイジェストで埋めてから制約を付ける。
class AddPasswordDigestToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :password_digest, :string

    unusable = BCrypt::Password.create(SecureRandom.hex(32))
    execute("UPDATE users SET password_digest = #{quote(unusable)} WHERE password_digest IS NULL")

    change_column_null :users, :password_digest, false
  end

  def down
    remove_column :users, :password_digest
  end
end
