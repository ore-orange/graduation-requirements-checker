# frozen_string_literal: true

namespace :graduation do
  desc '2024年度の現在の判定結果を test/fixtures/files/graduation_golden_2024.json に書き出す'
  task golden: :environment do
    File.write(GraduationGolden::FIXTURE_PATH, GraduationGolden.json(GraduationGolden.curriculum_document))
    puts "wrote #{GraduationGolden::FIXTURE_PATH}"
  end
end

