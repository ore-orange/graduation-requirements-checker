# frozen_string_literal: true

require 'test_helper'

# 便覧の科目表から「科目番号から区分が決まる科目」を外しても、学生の画面の区分計算が変わらないことを確かめる。
# graduation_assessment_filtered_test.rb(判定)の対になる。あちらは判定を測り、こちらは計画表・ダッシュボードが
# 使う course_category / category_credits を測る。画面の区分計算が番号パターンを見ないと、科目表から消えた科目が
# 「算入対象外」に落ち、修得済みの単位が区分から消える(判定は正しいまま、画面の単位の数字だけが間違う)。
class StudentWorkspaceFilteredTest < ActionView::TestCase
  tests StudentWorkspaceHelper

  test '絞り込んだ便覧でも、画面の区分ごとの修得単位と科目の区分が変わらない' do
    full = GraduationGolden.curriculum_document
    filtered = filter_all(GraduationGolden.curriculum_document)
    # 絞り込みが1件も効いていないのに緑になる空振りを防ぐ。
    assert_operator filtered.fetch('courses').size, :<, 200

    completed = GraduationGolden.cases(full).fetch('all_completed').fetch(:completed)
    enrollments = completed.map { |entry| enrollment(entry) }
    expected = screen_of(full, enrollments)
    actual = screen_of(filtered, enrollments)

    differing = expected[:categories].zip(actual[:categories]).reject { |before, after| before == after }
    assert_empty differing, '絞り込むと区分が変わる科目(絞り込み前, 絞り込み後)'
    assert_equal expected[:credits], actual[:credits]
    # 空振り防止。算入対象外に全部が落ちていれば、両側が同じ壊れ方でも一致してしまう。
    assert_operator actual[:credits].except('excluded').values.sum { |credits| credits[:earned] }, :>, 100
    assert_equal BigDecimal('0'), actual[:credits].fetch('excluded')[:earned]
  end

  private

  def enrollment(entry)
    course = Course.new(course_number: entry[:number], name: entry[:name], credits: entry[:credits])
    StudentCourse.new(course: course, enrollment_status: 'completed', credits_earned: entry[:credits])
  end

  # 画面が使う2つの計算。科目ごとの区分と、区分ごとの修得単位。
  def screen_of(document, enrollments)
    courses_by_number = document.fetch('courses').select { |course| course['number'].present? }
                                .index_by { |course| course['number'] }
    patterns = CurriculumImport::NumberPatterns.new(document['categories'])
    keys = document.fetch('categories').pluck('key') + ['excluded']
    {
      categories: enrollments.map do |e|
        [e.course.course_number, course_category(e.course, courses_by_number, patterns)]
      end,
      credits: keys.index_with { |key| category_credits(enrollments, [], [key], courses_by_number, patterns) }
    }
  end

  # 候補をすべて採用した便覧。手順は graduation_assessment_filtered_test.rb の filter_all と同じ。
  def filter_all(document)
    categories = document.fetch('categories')
    suggestions = CurriculumImport::CategoryInference.new(document.fetch('courses')).suggestions(categories)
    categories.each do |category|
      patterns = suggestions[category['key']]
      category['number_patterns'] = patterns if patterns
    end
    CurriculumImport::CoursePrune.call(document, drop_confirmed: true)
    document
  end
end

