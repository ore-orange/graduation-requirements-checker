# frozen_string_literal: true

require 'test_helper'

# 画面のプルダウンの選択肢。マスタ(Faculty/Department/Program)から作り、
# マスタに無い名前を持つ便覧があれば、その学科名も足す。
class CurriculumChoicesTest < ActiveSupport::TestCase
  setup { @choices = CurriculumChoices.new }

  test '学部は名前順に並べる' do
    assert_equal %w[工学部 理学部], @choices.faculties
  end

  test '学科は学部ごとにまとめる' do
    assert_equal({ '工学部' => ['工学科'], '理学部' => ['数理科学科'] }, @choices.departments)
  end

  test 'コースは学科ごとにまとめ、コースの無い学科は空で答える' do
    assert_equal({ '工学科' => ['知能情報コース'] }, @choices.courses)
    assert_equal ['知能情報コース'], @choices.courses_for('工学科')
    assert_empty @choices.courses_for('数理科学科')
    assert_empty @choices.courses_for(nil)
  end

  test 'マスタに無い学科名を持つ便覧があれば、その学部の学科に足す' do
    Curriculum.create!(slug: 'legacy', admission_year: 2024, faculty_name: '工学部', department_name: '旧情報工学科',
                       source_filename: 'legacy.pdf', pages: [])

    assert_equal %w[工学科 旧情報工学科], CurriculumChoices.new.departments.fetch('工学部')
  end

  test 'マスタのコースに割れる学科コース名は、学科として足さない' do
    Curriculum.create!(slug: 'known', admission_year: 2030, faculty_name: '工学部',
                       department_name: '工学科 知能情報コース', source_filename: 'k.pdf', pages: [])

    assert_equal ['工学科'], CurriculumChoices.new.departments.fetch('工学部')
  end

  test '入学年度は、学部名と学科コース名の両方を持つ便覧から新しい順に作る' do
    Curriculum.create!(slug: 'no_names', admission_year: 1999, source_filename: 'n.pdf', pages: [])
    Curriculum.create!(slug: 'newer', admission_year: 2030, faculty_name: '工学部',
                       department_name: '工学科 知能情報コース', source_filename: 'n2.pdf', pages: [])

    years = CurriculumChoices.new.admission_years

    assert_equal years.sort.reverse, years
    assert_includes years, 2030
    assert_not_includes years, 1999
  end
end

