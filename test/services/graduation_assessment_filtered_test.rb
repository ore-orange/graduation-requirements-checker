# frozen_string_literal: true

require 'test_helper'

# 便覧の科目表から「科目番号から区分が決まる科目」を外しても、学生の判定が変わらないことを確かめる。
#
# golden テスト(graduation_assessment_golden_test.rb)はこれを守らない。golden が読むのは 484 件のままの
# config/curricula/intelligent_informatics/2024.json で、ケースの履修も同じ JSON から作るので、絞り込みを
# 入れても定義上一致する。ここでは同じ履修を、絞り込む前の便覧と、候補をすべて採用して絞り込んだ便覧の
# 両方で判定し、区分ごとの算入単位・総単位・各規則の充足/不足/要確認を突き合わせる。
#
# 落ちたらテストを緩めない。落ちることは、絞り込みが判定を変えている(設計が間違っている)という知らせ。
class GraduationAssessmentFilteredTest < ActiveSupport::TestCase
  test '絞り込んだ便覧でも、2024年度の判定結果が変わらない' do
    full = GraduationGolden.curriculum_document
    # filter_all は文書を書き換えるので、絞り込む側は別に読む(full を比較の基準として残す)。
    filtered = filter_all(GraduationGolden.curriculum_document)
    # 絞り込みが1件も効いていないのに緑になる空振りを防ぐ。484件から確実に減っていること。
    assert_operator filtered.fetch('courses').size, :<, 200

    GraduationGolden.cases(full).each do |name, arguments|
      expected = GraduationAssessment.new(curriculum: full).call(**rekey(arguments, full))
      actual = GraduationAssessment.new(curriculum: filtered).call(**rekey(arguments, filtered))
      assert_equal GraduationGolden.snapshot(expected.actual), GraduationGolden.snapshot(actual.actual), name
      assert_equal GraduationGolden.snapshot(expected.projected), GraduationGolden.snapshot(actual.projected), name
    end
  end

  private

  # 候補をすべて採用した便覧。手順は RequirementsEdit::PatternAdoption と同じで、候補を区分の number_patterns に
  # 入れてから CoursePrune で科目表から外す(絞り込みの規則をテスト側で書き直さない)。
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

  # 履修の key を、その文書の科目表の key に振り替える。StudentWorkspace#catalogue_entries と同じ規則で、
  # 同じ番号の科目があればその key、無ければ "unmatched:<番号>"(番号も無ければ1件ずつ別の key)。
  #
  # これが無いと、絞り込んだ側で key が科目表に当たらないまま pattern_course へ落ちず、全科目が要確認になって
  # 「結果が違う」ことしか測らないテストになる。実際のアプリは履修の科目番号で振り替えるので、そうはならない。
  def rekey(arguments, document)
    by_number = document.fetch('courses').select { |course| course['number'] }.index_by { |course| course['number'] }
    unmatched = 0
    arguments.transform_values do |entries|
      entries.map do |entry|
        course = by_number[entry[:number]]
        next entry.merge(key: course.fetch('key')) if course

        number = entry[:number].presence
        entry.merge(key: "unmatched:#{number || (unmatched += 1)}")
      end
    end
  end
end

