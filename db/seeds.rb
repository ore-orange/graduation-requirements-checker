# frozen_string_literal: true

# 学部・学科は実在のマスタなので、環境を問わず作る。
require_relative 'seeds/academic_organizations'
AcademicOrganizations.load!

# 便覧は config/curricula のJSONを種にする。既にある便覧には触れない。
require_relative 'seeds/curricula'
CurriculumFiles.load!
