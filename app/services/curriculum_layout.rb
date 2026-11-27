# frozen_string_literal: true

# 便覧の文書のうち、画面の組み立てに使う部分(区分の和名・章・行・卒業総単位)を読む。
# 卒業要件そのもの(何を満たせば卒業か)は判定側が持ち、ここは見せ方だけを扱う。
#
# 章・行は、ビューがそのまま使える Symbol キーの Hash で返す(必要単位は :req、その表示文は :req_label)。
class CurriculumLayout
  def initialize(document)
    display = document['display']
    raise SetupIncomplete, 'カリキュラムに画面の章立て(display)が登録されていません。' unless display.is_a?(Hash)

    @total_credits = display.fetch('total_credits')
    @groups = display.fetch('groups').map { |group| build_group(group) }.freeze
    @labels = document.fetch('categories', []).to_h { |category| [category.fetch('key'), category.fetch('label')] }
  end

  attr_reader :total_credits, :groups

  def rows
    @rows ||= groups.flat_map { |group| group[:rows] }
  end

  def find_group(id)
    groups.find { |group| group[:id] == id }
  end

  # どの行にも集めている区分。
  def mapped_categories
    @mapped_categories ||= rows.flat_map { |row| row[:categories] }
  end

  # 区分の和名。登録の無い区分はキーのまま出す。
  def category_label(key)
    @labels.fetch(key, key)
  end

  private

  def build_group(group)
    { id: group.fetch('id'), title: group.fetch('title'), req: group['required_credits'],
      check_id: group.fetch('check_id'), rows: group.fetch('rows').map { |row| build_row(row) }.freeze }.freeze
  end

  def build_row(row)
    { id: row.fetch('id'), name: row.fetch('name'), subtitle: row['subtitle'], req: row['required_credits'],
      req_label: row['required_label'], categories: row.fetch('categories').freeze,
      check_ids: row.fetch('check_ids').freeze, credits_from_check: row['credits_from_check'] == true }.freeze
  end
end

