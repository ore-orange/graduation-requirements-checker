# frozen_string_literal: true

# 便覧PDFの取り込みフォーム(学部名・学科名・コース名のプルダウンと「その他」)の初期値。
module UploadFormHelper
  # 取り込みフォームの初期値。画面で選ばれていた学部・学科・コース・入学年度が、まだ便覧の無い組み合わせのとき、
  # それをフォームに入れておく(同じことを選び直さずに、そのままPDFを上げられる)。
  # 選択肢(Faculty/Department/Programにある名前)に無い名前は、「その他」を選び、自由入力欄に入れる。
  # 学部が新しければ、その下に既存の学科は無いので、学科も「その他」になる(コースも同様に、学科が新しいか、
  # 学科は既存でもその学科に無いコース名なら「その他」になる)。
  UploadDefaults = Struct.new(:faculty, :faculty_other, :department, :department_other, :course, :course_other,
                              :admission_year, :year_choices, keyword_init: true)

  def upload_form_defaults(selection, faculty_options, department_options, course_options)
    faculty, faculty_other = chosen_or_new(selection[:faculty], faculty_options)
    department, department_other = chosen_or_new_under(faculty, selection[:department], department_options)
    course, course_other = chosen_or_new_under(department, selection[:course], course_options)
    year = Integer(selection[:admission_year].to_s, 10, exception: false)
    year_choices = Curriculum.upload_year_choices(including: year)
    UploadDefaults.new(faculty: faculty, faculty_other: faculty_other,
                       department: department, department_other: department_other,
                       course: course, course_other: course_other, year_choices: year_choices,
                       admission_year: year_choices.include?(year) ? year : Time.zone.today.year)
  end

  private

  # 親(学部・学科)が決まっていないときは、どの親のものか分からないので選ばせない([nil, nil])。
  # 親が新しい(その他)ときは、既存の子は無いので空の選択肢で chosen_or_new に渡す。
  def chosen_or_new_under(parent, value, options_by_parent)
    return [nil, nil] unless parent

    chosen_or_new(value, parent == CurriculaController::NEW_PROGRAM ? [] : options_by_parent.fetch(parent, []))
  end

  # 値が選択肢にあれば [値, nil]、無ければ「その他」にして打った値として返す。空なら選んでいない。
  def chosen_or_new(value, options)
    return [nil, nil] if value.blank?

    options.include?(value) ? [value, nil] : [CurriculaController::NEW_PROGRAM, value]
  end
end

