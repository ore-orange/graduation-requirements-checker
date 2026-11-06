# frozen_string_literal: true

# 学部・学科は実在のマスタなので、環境を問わず作る。
require_relative 'seeds/academic_organizations'
AcademicOrganizations.load!

# 学科の中のコースも同じく実在のマスタ。
require_relative 'seeds/programs'
Programs.load!

# 便覧は卒業要件そのものなので、環境を問わず入れる。無ければ作る。ある行をファイルで上書きするのは開発・テストだけで、
# 本番では画面から公開した便覧が正本なので、流し直しても触れない（Curriculum.seed_from_file）。
Rails.root.glob('config/curricula/**/*.json').sort.each { |path| Curriculum.seed_from_file(path) }

# 架空の履修データは明示的なseed実行時のみ作成する。本番ではPUBLIC_DEMO=1のときだけ投入できる。
DemoData.load! if DemoAccount.enabled?
