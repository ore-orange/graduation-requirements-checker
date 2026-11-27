# frozen_string_literal: true

require 'test_helper'

# 2024年度の便覧での判定結果が、記録(test/fixtures/files/graduation_golden_2024.json)と1件も変わっていないこと。
# 判定の作りを置き換えても、学生に見える結果(状態・単位・文言・科目ごとの算入)は変えない。
# 意図して結果を変えたときだけ、bin/rails graduation:golden で記録を書き直し、差分をレビューで確かめる。
class GraduationGoldenTest < ActiveSupport::TestCase
  test '判定結果が記録と一致する' do
    recorded = JSON.parse(GraduationGolden::FIXTURE_PATH.read)
    current = JSON.parse(GraduationGolden.json(GraduationGolden.curriculum_document))

    assert_equal recorded.keys, current.keys
    recorded.each_key do |name|
      assert_equal recorded.fetch(name), current.fetch(name), "ケース #{name} の判定結果が記録と違います"
    end
  end

  test 'ケースは、狙った規則が実際に結果を分けている' do
    golden = JSON.parse(GraduationGolden::FIXTURE_PATH.read)
    status = ->(name, id) { golden.dig(name, 'actual', 'checks').find { |check| check['id'] == id }.fetch('status') }

    assert_equal %w[satisfied unmet],
                 [status.call('english_plus_one_language', 'foreign_language'),
                  status.call('english_plus_two_languages', 'foreign_language')]
    fusion = %w[fusion_one_provider fusion_split_providers fusion_own_course].map do |name|
      status.call(name, 'fusion_provider')
    end
    assert_equal %w[satisfied unmet unmet], fusion
    assert_equal 'satisfied', golden.dig('clean_single_path', 'actual', 'status')
    assert_equal 'needs_review', status.call('calculus_mixed_paths', 'calculus')
  end
end

