# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 算入の対象にしない科目を決める調整(設計書 項目9)。次の条件を書ける。書いた条件を**すべて**満たす科目だけを外す。
    #
    #   category           … 区分
    #   number_prefix      … 提供コース。便覧は提供コースの名前を持たないので、科目番号の接頭辞で表す
    #                        (grouped_max の group_by: number_prefix と同じ扱い)。
    #   number_prefix_mode … 接頭辞に「一致」(match。既定)か「以外」(except)か。
    #   numbers            … 名指しの科目番号(いくつでも)。どれか1つに当たればこの条件を満たす。
    #
    # 条件が1つも無い除外は、すべての科目を外してしまうので作らない(学生の単位が黙って消える)。
    #
    # 科目番号が読めない科目は、接頭辞の条件にも番号の条件にも当たらない(「一致」でも「以外」でも)。
    # 読めないことは、その接頭辞に属する根拠にも、属さない根拠にもならない。
    class Exclude
      PREFIX_MODES = %w[match except].freeze
      # 1つでも書かれていれば、何に当たるかが決まる欄。
      CONDITION_FIELDS = %w[category number_prefix numbers].freeze

      attr_reader :definition

      # 当たらないまま通る壊れた規則を作らないよう、読み込み時に定義を検める。
      def initialize(definition)
        @definition = definition
        require_text('reason')
        validate_category
        validate_number_prefix
        validate_prefix_mode
        validate_numbers
        require_any_condition
      end

      def id
        definition.fetch('id')
      end

      # 当たる科目には理由を、当たらない科目には nil を返す。
      def reason_for(course)
        return unless category_match?(course)
        return unless prefix_match?(course)
        return unless numbers_match?(course)

        definition.fetch('reason')
      end

      private

      def require_text(field)
        value = definition[field]
        return if value.is_a?(String) && !value.empty?

        raise ArgumentError, "exclude の#{field}は空でない文字列でなければなりません: #{value.inspect}"
      end

      # 区分は必須ではない(科目番号だけの除外を書けるようにするため)。書くなら空でない文字列。
      def validate_category
        require_text('category') if definition.key?('category') && !definition['category'].nil?
      end

      # 科目側の番号は CourseNumber.prefix が空白や全角を整えて読む。定義側も同じ整え方で変わらない値でなければ、
      # 一致しないまま黙って何も除外しなくなる。
      def validate_number_prefix
        return unless definition.key?('number_prefix')

        value = definition['number_prefix']
        return if value.is_a?(String) && CourseNumber.prefix("#{value}1") == value

        raise ArgumentError, "exclude の number_prefix は空白や全角を含まない接頭辞でなければなりません: #{value.inspect}"
      end

      # 「一致/以外」は、当てる接頭辞があって初めて意味を持つ。接頭辞の無い「以外」は、すべての科目に当たってしまう。
      def validate_prefix_mode
        return unless definition.key?('number_prefix_mode')

        mode = definition['number_prefix_mode']
        unless PREFIX_MODES.include?(mode)
          raise ArgumentError, "exclude の number_prefix_mode は #{PREFIX_MODES.join('・')} のどれかです: #{mode.inspect}"
        end
        return if definition.key?('number_prefix')

        raise ArgumentError, 'exclude の number_prefix_mode は、number_prefix と一緒に書いてください。'
      end

      def validate_numbers
        return unless definition.key?('numbers')

        value = definition['numbers']
        return if value.is_a?(Array) && value.all?(String)

        raise ArgumentError, "exclude の numbers は科目番号(文字列)の配列でなければなりません: #{value.inspect}"
      end

      # 条件が全部空だと、すべての科目を除外する。断る。
      def require_any_condition
        return if CONDITION_FIELDS.any? { |field| present_condition?(field) }

        raise ArgumentError, '算入しない科目(exclude)には、区分・提供コース(科目番号の接頭辞)・科目番号のどれかを' \
                             '書いてください。条件が1つも無いと、すべての科目を算入から外します。'
      end

      def present_condition?(field)
        value = definition[field]
        value.is_a?(Array) ? normalized_numbers.any? : value.is_a?(String) && !value.strip.empty?
      end

      def category_match?(course)
        return true unless present_condition?('category')

        course['category'] == definition['category']
      end

      def prefix_match?(course)
        return true unless present_condition?('number_prefix')

        prefix = CourseNumber.prefix(course['number'])
        return false if prefix.nil? # 読めない番号は、一致の根拠にも「以外」の根拠にもならない

        except? ? prefix != definition['number_prefix'] : prefix == definition['number_prefix']
      end

      def except? = definition['number_prefix_mode'] == 'except'

      def numbers_match?(course)
        return true unless present_condition?('numbers')

        number = CourseNumber.normalize(course['number'])
        return false if number.empty?

        normalized_numbers.include?(number)
      end

      def normalized_numbers
        @normalized_numbers ||= Array(definition['numbers']).grep(String)
                                                            .map { |number| CourseNumber.normalize(number) }
                                                            .reject(&:empty?)
      end
    end
  end
end

