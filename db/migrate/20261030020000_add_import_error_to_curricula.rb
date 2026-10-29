# frozen_string_literal: true

# 下書きを作るときにページ数を数えられなかった理由。下書き自体は作るので、画面に出せるようここに残す。
class AddImportErrorToCurricula < ActiveRecord::Migration[8.1]
  def change
    add_column :curricula, :import_error, :text
  end
end
