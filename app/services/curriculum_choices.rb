# frozen_string_literal: true

# 卒業要件の確認画面と便覧の取り込みフォームが出す、学部・学科・コース・入学年度の選択肢。
#
# 学部・学科・コースは Faculty/Department/Program のマスタから作る(便覧の有無を問わない。まだ便覧の無い
# 組み合わせも選べる)。入学年度だけは、実在する便覧(公開済みも下書きも)の実データから作る
# (下書きだけの年度も選べるように)。
#
# 既存の便覧が、マスタに無い学部・学科コース名を持っていることもある(マスタに追加する前の下書きなど)。
# そういう組み合わせも選べるよう、マスタの一覧に足す(コースに割れる名前は、Programの組で判定済みなので足さない)。
#
# 1回の表示で何度も引かれるので、問い合わせた結果は持ち回す。
class CurriculumChoices
  # 学部名・学科コース名のプルダウンで「その他（新しく登録する）」を選んだ印。名前としては保存しない。
  # 空文字にしないのは、「何も選んでいない」と区別するため。選ぶと、横の自由入力欄(*_name_other)の値が名前になる。
  NEW_PROGRAM = '__other__'

  # 学部名の一覧
  def faculties = @faculties ||= Faculty.order(:name).pluck(:name)

  # { 学部名 => [学科名] }。プルダウンの <optgroup label="学部名"> になる。
  def departments
    @departments ||= group(Department.joins(:faculty).order('faculties.name', :name)
                                     .pluck('faculties.name', :name))
                     .merge!(legacy_departments) { |_faculty, known, extra| known | extra }
  end

  # { 学科名 => [コース名] }。プルダウンの <optgroup label="学科名"> になる。
  def courses
    @courses ||= group(Program.joins(:department).order('departments.name', :name)
                              .pluck('departments.name', :name))
  end

  # その学科のコース。コースの無い学科・知らない学科は空。
  def courses_for(department_name) = courses.fetch(department_name.to_s, [])

  # 便覧のある入学年度(新しい順)
  def admission_years
    @admission_years ||= named_curricula.distinct.order(admission_year: :desc).pluck(:admission_year)
  end

  private

  def group(pairs) = pairs.group_by(&:first).transform_values { |rows| rows.map(&:last) }

  # マスタに無い学部・学科コース名を持つ便覧から足す学科名。{ 学部名 => [学科名] }
  def legacy_departments
    named_curricula.distinct.pluck(:faculty_name, :department_name).each_with_object({}) do |(faculty, name), extra|
      department, course = Program.department_and_course_for(name)
      next if course # Programの組で判定済み(マスタの学科・コースに載っている)

      (extra[faculty] ||= []) << department
    end
  end

  # 学部名と学科コース名の両方を持つ便覧。
  # where.not に2列を渡すと「2列とも空、ではない」になり、片方だけ空の行が残ってしまう。1列ずつ除く。
  def named_curricula
    @named_curricula ||= Curriculum.where.not(faculty_name: [nil, '']).where.not(department_name: [nil, ''])
  end
end

