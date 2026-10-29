# frozen_string_literal: true

require 'test_helper'

# 判定ルールを作り替えても2024年度の答えが変わらないことを、記録済みの結果と突き合わせて確かめる。
# 記録の作り直しは `bin/rails graduation:golden`。意図した変更のときだけ行う。
class GraduationAssessmentGoldenTest < ActiveSupport::TestCase
  test '2024年度の判定結果が記録と一致する' do
    # 整形済みの文字列で比べると、食い違った箇所が行単位の差分で読める。
    assert_equal GraduationGolden::FIXTURE_PATH.read, GraduationGolden.json(GraduationGolden.curriculum_document)
  end
end

