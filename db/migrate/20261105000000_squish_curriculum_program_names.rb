# frozen_string_literal: true

# 学部名・学科コース名は、画面から上げるときに前後・途中の空白(全角を含む)を揃える(Curriculum の normalizes)。
# 以前は自由入力で、揃えていない値が残っていることがある。残ると、選択肢にはそのまま出るのに、選んで送った値は
# 揃えられて照合に合わず、同じ課程が別の識別名になり、来年度の便覧が別の課程として並ぶ。ここで既存の行も揃える。
class SquishCurriculumProgramNames < ActiveRecord::Migration[8.1]
  # モデルの検証や normalizes に依存しない(あとでモデルが変わっても、この移行の結果が変わらない)。
  class MigrationCurriculum < ActiveRecord::Base
    self.table_name = 'curricula'
  end

  def up
    MigrationCurriculum.where.not(faculty_name: nil).or(MigrationCurriculum.where.not(department_name: nil)).find_each do |row|
      squished = { faculty_name: row.faculty_name&.squish, department_name: row.department_name&.squish }
      row.update_columns(squished) if squished != row.slice(:faculty_name, :department_name).symbolize_keys
    end
  end

  # 揃える前の空白は戻せない。戻す必要もない(揃った値は、揃える前の値と同じ課程を指す)。
  def down; end
end
