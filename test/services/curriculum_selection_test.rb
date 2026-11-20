# frozen_string_literal: true

require 'test_helper'

# 画面で選ばれた対象(学部・学科・コース・入学年度)の解釈。値はクエリから来るので信用しない。
class CurriculumSelectionTest < ActiveSupport::TestCase
  FACULTY = '工学部'
  DEPARTMENT = '工学科'
  COURSE = '知能情報コース'

  def selection(**params) = CurriculumSelection.new(params)

  def full(**overrides)
    selection(faculty: FACULTY, department: DEPARTMENT, course: COURSE, admission_year: '2024', **overrides)
  end

  test '文字列でない値・制御文字・壊れたエンコードは、指定されなかった扱いにする' do
    assert_nil selection(faculty: %w[工学部]).faculty
    assert_nil selection(faculty: { name: '工学部' }).faculty
    assert_nil selection(faculty: "工学部\0").faculty
    assert_nil selection(faculty: (+"\xff").force_encoding('UTF-8')).faculty
    assert_not selection(faculty: '  ').given?
  end

  test '前後の空白は落とし、長すぎる値は切り詰める' do
    assert_equal FACULTY, selection(faculty: "  #{FACULTY}  ").faculty
    assert_equal CurriculumSelection::MAX_LENGTH, selection(faculty: 'あ' * 200).faculty.length
  end

  test '学科にコースがあるときは、コースまで選ばないと揃わない' do
    assert full.complete?
    assert_not full(course: nil).complete?
    assert full(course: nil).named? # 画面は開ける(コースを選んでもらう)
  end

  test 'コースの無い学科は、学科までで揃う' do
    assert full(department: '数理科学科', course: nil).complete?
  end

  test '学科名だけで登録された便覧があるときは、コースを求めない' do
    Curriculum.create!(slug: 'dept_only', admission_year: 2024, faculty_name: FACULTY, department_name: DEPARTMENT,
                       source_filename: 'd.pdf', pages: [])

    assert full(course: nil).complete?
  end

  test '学科コース名は、便覧が持つ1つの文字列の形に結ぶ' do
    assert_equal "#{DEPARTMENT} #{COURSE}", full.department_name
    assert_equal DEPARTMENT, full(course: nil).department_name
  end

  test '便覧からは、学科コース名を2つの欄に分けて作る' do
    curriculum = Curriculum.new(faculty_name: FACULTY, department_name: "#{DEPARTMENT} #{COURSE}",
                                admission_year: 2024)
    built = CurriculumSelection.for(curriculum)

    assert_equal [FACULTY, DEPARTMENT, COURSE, '2024'],
                 [built.faculty, built.department, built.course, built.admission_year]
    assert_equal({ faculty: FACULTY, department: DEPARTMENT, course: COURSE, admission_year: '2024' },
                 built.to_params)
  end

  test '指定が揃っていなければ、便覧は引かない' do
    assert_nil full(admission_year: nil).published
    assert_empty full(admission_year: nil).drafts
  end

  test '範囲の外の年度や数字でない年度は、何も見つからないだけにする' do
    assert_nil full(admission_year: '99999').published
    assert_nil full(admission_year: 'にせん').published
  end

  test '公開済みは新しい順に1つ、下書きは更新の新しい順に並べる' do
    published = Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: 2024)

    assert_equal published, full.published
    assert_empty full.drafts
  end
end

