# frozen_string_literal: true

namespace :master do
  desc '学部・学科・コースのマスタと、便覧の初期データを投入する。何度流しても増えない。'
  task load: :environment do
    # db/ は autoload の対象外なので明示的に読み込む。db/seeds.rb と同じ定義を使う。
    require Rails.root.join('db/seeds/academic_organizations').to_s
    require Rails.root.join('db/seeds/curricula').to_s

    AcademicOrganizations.load!
    # 便覧は、同じ slug・入学年度の公開済みが無いときだけ入れる。管理者が直した便覧をファイルで戻さない。
    CurriculumFiles.load!
    Rails.logger.info("master:load 学部#{Faculty.count}件 学科#{Department.count}件 コース#{Program.count}件 " \
                      "便覧#{Curriculum.count}件")
  end
end

