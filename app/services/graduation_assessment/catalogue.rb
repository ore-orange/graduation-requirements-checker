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

    attr_reader :courses, :requirements, :categories, :conditions, :adjustments, :display

    # categories・rules・display は format 2 の便覧にだけある。旧形式の便覧では、どれも空になる。
    # 規則は読み込み時に作る。壊れた調整（Rules.adjustment が拒むもの）は、学生の判定の最中ではなく便覧を読む時点で例外にする。
    def initialize(document)
      @courses = document.fetch('courses')
      @by_key = @courses.index_by { |course| course.fetch('key') }
      @requirements = document.fetch('requirements')
      @categories = Array(document['categories'])
      @category_labels = @categories.to_h { |category| [category['key'], category['label']] }
      @display = document['display'] || {}
      @rules_present = document['rules'].present?
      @conditions, @adjustments = build_rules(Array(document['rules']))
    end

    # 区分の和名は便覧の categories に1か所だけ持つ。categories がない（旧形式の）便覧ではキーをそのまま返す。
    def label_for(key)
      @category_labels[key] || key
    end

    def category_keys
      categories.pluck('key')
    end

    # 卒業総単位に数える区分。counts_toward_total が無い区分は数える。
    def counted_category_keys
      categories.reject { |category| category['counts_toward_total'] == false }.pluck('key')
    end

    def find(key)
      @by_key[key]
    end

    def course_for(number)
      @by_number ||= courses.select { |course| course['number'] }.index_by { |course| course['number'] }
      @by_number[number]
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

    # rules がある便覧では one_of_paths の経路に挙がった役割。旧形式の便覧では requirements から作る。
    def required_roles
      @required_roles ||= (@rules_present ? roles_from_rules : roles_from_requirements).uniq
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

    private

    def roles_from_rules
      conditions.grep(Rules::OneOfPaths).flat_map { |rule| rule.definition.fetch('paths').flatten }
    end

    def roles_from_requirements
      requirements.fetch('english_roles') + [requirements.fetch('japanese_role')] +
        requirements.fetch('calculus_paths').flatten + requirements.fetch('physics_roles')
    end

    # 並び順は画面に出る順なので、振り分けても rules の順を保つ。
    def build_rules(definitions)
      adjustments, conditions = definitions.partition { |definition| definition.is_a?(Hash) && Rules::ADJUSTMENTS.key?(definition['type']) }
      [conditions.map { |definition| Rules.condition(definition) },
       adjustments.map { |definition| Rules.adjustment(definition) }]
    end
  end
end

