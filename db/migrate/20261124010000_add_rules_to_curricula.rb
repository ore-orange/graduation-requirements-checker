# frozen_string_literal: true

# 卒業判定を、コードに書いた知能情報コース専用の規則から、便覧の rules を読む形に替えた(format_version 2)。
# 既にDBにある便覧の行は master:load が書き換えないので、ファイルにある rules を、まだ持っていない行にだけ写す。
# rules を持たない便覧は、判定が例外になってしまうため。
class AddRulesToCurricula < ActiveRecord::Migration[8.1]
  ROOT = Rails.root.join('config/curricula')
  # 戻すときに、旧形式の判定が読む requirements を復元する(2024年度の知能情報コースの値)。
  LEGACY_REQUIREMENTS = {
    %w[intelligent_informatics 2024] => {
      'english_roles' => %w[university_english english_reading_intermediate],
      'japanese_role' => 'japanese_expression',
      'calculus_paths' => [%w[calculus_st_1 calculus_st_2], %w[calculus_intro_1 calculus_intro_2]],
      'physics_roles' => %w[physics_1 physics_intro_1]
    }
  }.freeze

  # モデルの今後の変更に左右されないよう、移行の中だけで使う。
  class Row < ActiveRecord::Base
    self.table_name = 'curricula'
  end

  def up
    Row.where.not(published_at: nil).find_each do |row|
      next if row.document.key?('rules')

      path = ROOT.join(row.slug, "#{row.admission_year}.json")
      next unless path.file?

      file = JSON.parse(path.read)
      next unless file.key?('rules')

      document = row.document.except('requirements').merge(file.slice('rules', 'format_version'))
      row.update_columns(document: document)
    end
  end

  def down
    Row.find_each do |row|
      next unless row.document.key?('rules')

      legacy = LEGACY_REQUIREMENTS[[row.slug, row.admission_year.to_s]]
      document = row.document.except('rules').merge('format_version' => 1)
      document['requirements'] = legacy if legacy
      row.update_columns(document: document)
    end
  end
end

