# frozen_string_literal: true

class GraduationAssessment
  class Catalogue
    ZERO = BigDecimal('0')
    # 入れ子の規則を持つ欄。区分の参照を検めるときに、ここをたどる。
    NESTED_RULES = %w[options conditions].freeze
    BOOLEANS = [true, false].freeze

    attr_reader :courses, :categories, :conditions, :adjustments, :display, :required_roles

    # categories・rules・display は format 2 の便覧にだけある。旧形式の便覧では、どれも空になる。
    # 規則は読み込み時に作る。壊れた便覧（重複した科目番号・区分、宛先の無い区分の参照、paths の無い
    # one_of_paths、Rules.adjustment が拒む調整）は、学生の判定の最中ではなく便覧を読む時点で例外にする。
    def initialize(document)
      @courses = document.fetch('courses')
      @by_key = @courses.index_by { |course| course.fetch('key') }
      @categories = Array(document['categories'])
      @category_labels = @categories.to_h { |category| [category['key'], category['label']] }
      @display = document['display'] || {}
      rules_document = rules_document?(document)
      validate(document) if rules_document
      @conditions, @adjustments = build_rules(Array(document['rules']))
      validate_conditions if rules_document
      @exclusions = @adjustments.grep(Rules::Exclude)
      @required_roles = roles_from_rules.uniq
    end

    # 区分の和名は便覧の categories に1か所だけ持つ。categories がない（旧形式の）便覧ではキーをそのまま返す。
    def label_for(key)
      @category_labels[key] || key
    end

    def category_keys
      @category_keys ||= categories.pluck('key')
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

    def specified?(course)
      course['required'] || roles(course).intersect?(required_roles)
    end

    def mandatory
      courses.select { |course| course['required'] }
    end

    # 算入の対象外にする理由。便覧の exclude 規則を並び順に当て、最初に当たった理由を返す。
    def exclusion(course)
      @exclusions.filter_map { |rule| rule.reason_for(course) }.first
    end

    private

    def roles_from_rules
      conditions.grep(Rules::OneOfPaths).flat_map { |rule| rule.definition.fetch('paths').flatten }
    end

    # 並び順は画面に出る順なので、振り分けても rules の順を保つ。
    def build_rules(definitions)
      adjustments, conditions = definitions.partition { |definition| definition.is_a?(Hash) && Rules::ADJUSTMENTS.key?(definition['type']) }
      [conditions.map { |definition| Rules.condition(definition) },
       adjustments.map { |definition| Rules.adjustment(definition) }]
    end

    # categories・rules のどちらかを持つ便覧は、規則で判定する便覧として検める。
    # format_version の記載には頼らない。欄だけ format 2 で version が 1 のままの便覧を素通りさせないため。
    def rules_document?(document)
      document['categories'].present? || document['rules'].present?
    end

    def validate(document)
      validate_course_numbers
      validate_categories
      validate_rule_categories(Array(document['rules']))
      validate_display(document['display']) if document.key?('display')
    end

    # display は画面に出る数字と行の元。欄の綴り違いや null は、黙って別の数字や「必要単位なしの行」になり、
    # 満たしていない要件を画面から消してしまう。空欄のまま出る方が直せるので、読み込み時に弾く。
    # display を持たない便覧はここでは弾かない（画面を開いたときに KeyError になる）。
    def validate_display(display)
      raise ArgumentError, 'display はハッシュでなければなりません' unless display.is_a?(Hash)

      problems = []
      problems << 'total_credits は正の数でなければなりません' unless positive_number?(display['total_credits'])
      groups = display['groups']
      if groups.is_a?(Array)
        groups.each_with_index { |group, index| problems.concat(group_problems(group, "groups[#{index}]")) }
      else
        problems << 'groups は配列でなければなりません'
      end
      problems.concat(subtotal_problems(display['subtotals']))
      raise ArgumentError, "display が正しくありません: #{problems.join('、')}" if problems.any?
    end

    def group_problems(group, path)
      return ["#{path} はハッシュでなければなりません"] unless group.is_a?(Hash)

      problems = %w[id title].reject { |field| present_string?(group[field]) }.map { |field| "#{path}.#{field} がありません" }
      problems << "#{path}.required_credits は0以上の数でなければなりません" unless non_negative_number?(group['required_credits'])
      return problems << "#{path}.rows は配列でなければなりません" unless group['rows'].is_a?(Array)

      group['rows'].each_with_index { |row, index| problems.concat(row_problems(row, "#{path}.rows[#{index}]")) }
      problems
    end

    def row_problems(row, path)
      return ["#{path} はハッシュでなければなりません"] unless row.is_a?(Hash)

      problems = %w[id name].reject { |field| present_string?(row[field]) }.map { |field| "#{path}.#{field} がありません" }
      # 欄が無い・綴りが違うと false 扱いになり、算入上限が効いた判定の単位と食い違う数字が出る。
      unless BOOLEANS.include?(row['credits_from_check'])
        problems << "#{path}.credits_from_check は true か false でなければなりません"
      end
      problems.concat(row_requirement_problems(row, path))
    end

    # 必要単位を持たない行は「内数」の行として、バーも判定も出さない。意図した行だけがそうなるよう、
    # 必要単位が null の行にはその理由を表すラベルを求める。綴り違いで必要単位が消えた行は、ここで弾かれる。
    def row_requirement_problems(row, path)
      credits = row['required_credits']
      return ["#{path}.required_credits は0以上の数か null でなければなりません"] unless credits.nil? || non_negative_number?(credits)

      return [] unless credits.nil? && !present_string?(row['required_label'])

      ["#{path} は required_credits が null なので required_label が必要です"]
    end

    def subtotal_problems(subtotals)
      return [] if subtotals.nil?
      return ['subtotals は配列でなければなりません'] unless subtotals.is_a?(Array)

      subtotals.each_with_index.filter_map do |subtotal, index|
        next if subtotal.is_a?(Hash) && non_negative_number?(subtotal['required_credits'])

        "subtotals[#{index}].required_credits は0以上の数でなければなりません"
      end
    end

    def positive_number?(value) = number?(value) && value.positive?
    def non_negative_number?(value) = number?(value) && !value.negative?
    def number?(value) = value.is_a?(Numeric) && value.to_f.finite?
    def present_string?(value) = value.is_a?(String) && !value.strip.empty?

    # 条件が1つも無い便覧は、何も確かめないまま判定を返す。規則を書く前の年度のファイルがこれになる。
    def validate_conditions
      raise ArgumentError, '規則で判定する便覧に条件が1つもありません' if conditions.empty?

      invalid = conditions.grep(Rules::AllRequired)
                          .reject { |rule| category_list?(rule.definition['required_categories']) }
                          .map { |rule| rule.definition['id'] }
      return if invalid.empty?

      raise ArgumentError,
            "all_required の required_categories は空でない区分キーの配列でなければなりません: #{invalid.join('、')}"
    end

    # 欄の有無ではなく中身を見る。null も空の配列も、書き手の意図が読めないまま区分の見張りを無くす。
    def category_list?(value)
      value.is_a?(Array) && value.any? && value.all? { |key| key.is_a?(String) && !key.empty? }
    end

    # 科目番号の重複は、course_for が黙って片方を返し、学生の履修が違う科目に解決される。
    # 番号の無い科目（分類表にしか載っていない科目）は course_for で引けないだけなので弾かない。
    def validate_course_numbers
      numbers = courses.filter_map { |course| course['number'].presence }
      duplicates = numbers.tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise ArgumentError, "courses の number が重複しています: #{duplicates.sort_by(&:to_s).join('、')}"
    end

    # key の無い区分は category_keys に nil を混ぜ、重複した key は和名の対応表を後勝ちで潰す。
    def validate_categories
      raise ArgumentError, 'categories の要素に key がありません' if category_keys.any?(&:blank?)

      duplicates = category_keys.tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise ArgumentError, "categories の key が重複しています: #{duplicates.sort_by(&:to_s).join('、')}"
    end

    # 便覧に無い区分を指す規則は、何も数えないまま不足とも充足とも言ってしまう。
    def validate_rule_categories(definitions)
      unknown = definitions.flat_map { |definition| referenced_categories(definition) }.uniq - category_keys
      return if unknown.empty?

      raise ArgumentError, "rules が categories に無い区分を参照しています: #{unknown.sort_by(&:to_s).join('、')}"
    end

    def referenced_categories(definition)
      return [] unless definition.is_a?(Hash)

      Array(definition['category']) + Array(definition['categories']) + Array(definition['required_categories']) +
        NESTED_RULES.flat_map { |field| Array(definition[field]).flat_map { |child| referenced_categories(child) } }
    end
  end
end

