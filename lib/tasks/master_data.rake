# frozen_string_literal: true

namespace :master do
  desc '学部・学科・コースのマスタを投入する。何度流しても増えない。'
  task load: :environment do
    # db/ は autoload の対象外なので明示的に読み込む。db/seeds.rb と同じ定義を使う。
    require Rails.root.join('db/seeds/academic_organizations').to_s

    AcademicOrganizations.load!
    Rails.logger.info("master:load 学部#{Faculty.count}件 学科#{Department.count}件 コース#{Program.count}件")
  end
end

