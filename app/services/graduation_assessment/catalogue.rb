# frozen_string_literal: true

class GraduationAssessment
  # 便覧の文書(科目表・区分・規則)を、判定が引ける形にする。卒業要件そのものはコードに持たず、rules から組み立てる。
  class Catalogue
    ZERO = BigDecimal('0')

    attr_reader :courses, :conditions, :category_keys

    def initialize(document)
      @courses = document.fetch('courses')
      @by_key = @courses.index_by { |course| course.fetch('key') }
      @category_keys = document.fetch('categories').map { |category| category.fetch('key') }
      rules = document.fetch('rules')
      @adjustments = rules.select { |rule| Rules.adjustment?(rule) }.map { |rule| Rules.adjustment(rule) }
      @conditions = rules.reject { |rule| Rules.adjustment?(rule) }.map { |rule| Rules.condition(rule) }
      # 条件の無い便覧は、何も確かめないまま判定を返してしまう。
      raise ArgumentError, '便覧に判定の条件(rules)がありません。' if @conditions.empty?
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

    def mandatory
      courses.select { |course| course['required'] }
    end

    # 経路(one_of_paths)を持つ条件。重複算入の確認(reconcile)に使う。
    def path_rules
      @path_rules ||= conditions.grep(Rules::OneOfPaths)
    end

    # 経路の規則が指定する科目か。必修科目と並んで、所定単位どおりに修得しているかを確かめる。
    def specified?(course)
      @path_roles ||= path_rules.flat_map(&:roles)
      course['required'] || roles(course).intersect?(@path_roles)
    end

    # 入れ子も含めた grouped_max。グループを決められない科目に注記するため。
    def grouped_rules
      @grouped_rules ||= conditions.flat_map(&:grouped_rules)
    end

    def caps
      @adjustments.grep(Rules::Cap)
    end

    # 算入の対象にしない理由。当たらなければ nil。
    def exclusion(course)
      @adjustments.grep(Rules::Exclude).find { |rule| rule.match?(course) }&.reason
    end
  end
end

