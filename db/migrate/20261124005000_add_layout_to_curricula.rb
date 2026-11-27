# frozen_string_literal: true

# 画面の章立て(display)と区分の和名(categories)を、便覧の文書から読むようにした。
# 既にDBにある便覧の行は master:load が書き換えないので、ファイルにある章立てを、まだ持っていない行にだけ写す。
# 章立てを持たない便覧は、学生の画面が初期設定の案内になってしまうため。
#
# 番号は 20261124000000 から移した。coursesとcourse_offeringsを統合するmigrationが
# 同じ番号を使っていて、両方がmainに入ると db:migrate が版番号の重複で止まるため。
class AddLayoutToCurricula < ActiveRecord::Migration[8.1]
  ROOT = Rails.root.join('config/curricula')
  KEYS = %w[categories display].freeze

  # モデルの今後の変更に左右されないよう、移行の中だけで使う。
  class Row < ActiveRecord::Base
    self.table_name = 'curricula'
  end

  def up
    Row.where.not(published_at: nil).find_each do |row|
      next if row.document.key?('display')

      path = ROOT.join(row.slug, "#{row.admission_year}.json")
      next unless path.file?

      layout = JSON.parse(path.read).slice(*KEYS)
      row.update_columns(document: row.document.merge(layout)) if layout.key?('display')
    end
  end

  def down
    Row.find_each { |row| row.update_columns(document: row.document.except(*KEYS)) }
  end
end

