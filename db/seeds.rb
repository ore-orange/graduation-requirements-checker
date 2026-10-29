# frozen_string_literal: true

# 学部・学科は実在のマスタなので、環境を問わず作る。
require_relative 'seeds/academic_organizations'
AcademicOrganizations.load!

# 便覧は卒業要件そのものなので、環境を問わず入れる。流し直しても、同じ便覧の行を更新するだけで増えない。
Rails.root.glob('config/curricula/**/*.json').sort.each { |path| Curriculum.seed_from_file(path) }

# 架空の履修データは明示的なseed実行時のみ作成する。本番ではPUBLIC_DEMO=1のときだけ投入できる。
DemoData.load! if DemoAccount.enabled?
