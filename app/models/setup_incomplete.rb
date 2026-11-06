# frozen_string_literal: true

# 画面を出すのに必要なデータがまだ揃っていない。利用者には初期設定の案内を見せる。
# デモかどうかとは関係なく、ログイン済みの一般ユーザーにも起こる。
class SetupIncomplete < StandardError; end

