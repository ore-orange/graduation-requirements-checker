# frozen_string_literal: true

# 便覧PDFから読み取った下書きのための欄。PDFは保管しないので、ページごとの文字と読み取りの状態をここに残す。
# pages の要素は { page:, text:, status: pending|read|failed, error:, contributed:, warnings: }。
class AddImportColumnsToCurricula < ActiveRecord::Migration[8.1]
  def change
    add_column :curricula, :source_filename, :string
    add_column :curricula, :pages, :jsonb, null: false, default: []
  end
end

