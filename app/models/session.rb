# frozen_string_literal: true

# ログイン状態そのもの。Cookieが指す先で、消せばその端末だけログアウトできる。
class Session < ApplicationRecord
  belongs_to :user
end

