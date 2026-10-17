# frozen_string_literal: true

class GraduationAssessment
  class Catalogue
    ZERO = BigDecimal('0')
    COMMON = %w[health humanities social natural integrated career regional japanese english foreign_language].freeze
    REQUIRED = {
      'required_information' => ['情報技術系必修', 2],
      'required_comprehensive' => ['総合力演習必修', 7],
      'required_research' => ['研究・基礎演習・実験必修', 16],
      'required_math' => ['数学基礎必修', 6],
      'required_core' => ['知能情報コア必修', 26]
    }.freeze
    INNER = %w[elective_math advanced related].freeze
    ELECTIVE = (INNER + %w[fusion free]).freeze
    CATEGORIES = (COMMON + ['basic'] + REQUIRED.keys + ELECTIVE + ['excluded']).freeze
    PROVIDERS = %w[mechanical energy electrical electronics civil architecture].freeze
    SOURCE = 'docs/kogaku_chinot_y24.pdf（便覧10ページ・PDF11ページ）'
    REQUIRED_SOURCE = 'docs/kogaku_chinot_y24.pdf（便覧1・10・11ページ・PDF2・11・12ページ）'

    attr_reader :courses, :requirements

    def initialize(document)
      @courses = document.fetch('courses')
      @by_key = @courses.index_by { |course| course.fetch('key') }
      @requirements = document.fetch('requirements')
    end

    def find(key)
      @by_key[key]
    end

    def roles(course)
      course.fetch('roles', [])
    end

    def role_candidates(role)
      courses.select { |course| roles(course).include?(role) }
    end

    def role_names(role)
      role_candidates(role).pluck('name')
    end

    def required_roles
      @required_roles ||= (requirements.fetch('english_roles') + [requirements.fetch('japanese_role')] +
        requirements.fetch('calculus_paths').flatten + requirements.fetch('physics_roles')).uniq
    end

    def specified?(course)
      course['required'] || roles(course).intersect?(required_roles)
    end

    def mandatory
      courses.select { |course| course['required'] }
    end

    def exclusion(course)
      return '卒業単位への算入対象外' if course['category'] == 'excluded'
      return unless course['category'] == 'fusion' && course['provider'] == 'intelligent_informatics'

      '自コース提供の工学融合科目は登録・算入不可'
    end
  end
end

