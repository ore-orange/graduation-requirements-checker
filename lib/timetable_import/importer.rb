# frozen_string_literal: true

module TimetableImport
  # 人が確認した行(日本語の見出しをキーにしたハッシュ)を courses / course_offerings に保存する。
  # 1つでもエラーがあれば何も保存しない。apply: false(既定)ではトランザクションを巻き戻し、
  # 保存した場合と同じ件数だけを返す(dry-run)。
  #
  # 既存の講義と同じかどうかは、名前・番号では自動判定しない。行に「既存講義ID」があればその講義に紐付け、
  # 無ければ新しい講義として登録する。ただし同じ名前・番号の講義が既にあるのに「新規登録」の指定も無い行は、
  # 人が選び忘れているのでエラーにする。
  class Importer
    Result = Struct.new(:errors, :created_courses, :created_offerings, :updated_offerings, :unchanged_offerings,
                        :applied, keyword_init: true) do
      def ok? = errors.empty?
    end

    UNRESOLVED_MESSAGE = '同じ名前・番号の講義が登録済みです。同じ講義として扱うか、別の講義として登録するかを選んでください。'

    # 年度と学科は行ごとではなく取り込み全体で1つなので、行のハッシュには入れず引数で受ける。
    def initialize(rows, year:, department_id:)
      @rows = rows
      @year = year
      @department_id = department_id
    end

    def call(apply: false)
      result = Result.new(errors: [], created_courses: 0, created_offerings: 0, updated_offerings: 0,
                          unchanged_offerings: 0, applied: false)
      @new_courses = {}
      ActiveRecord::Base.transaction do
        @rows.each_with_index { |row, index| import_row(row, index + 1, result) }
        raise ActiveRecord::Rollback if result.errors.any? || !apply

        result.applied = true
      end
      result
    end

    private

    # lineはエラー表示用の行番号。確認画面の「行」列と同じ番号にして、該当行を探せるようにする。
    def import_row(row, line, result)
      attrs = RowAttributes.new(row)
      if attrs.errors.any?
        attrs.errors.each { |message| result.errors << "#{line}行目(#{row['科目名']}): #{message}" }
        return
      end

      course = resolve_course(attrs, result, line)
      save_offering(course, attrs, result, line) if course
    end

    def resolve_course(attrs, result, line)
      return linked_course(attrs, result, line) if attrs.course_id

      key = [attrs.course_number, attrs.name]
      # 同じPDFの中で、同じ名前・番号の行は、先に登録する講義にまとめる
      return @new_courses[key] if @new_courses.key?(key)

      if !attrs.register_as_new && same_course_registered?(attrs)
        result.errors << "#{line}行目(#{attrs.name}): #{UNRESOLVED_MESSAGE}"
        return nil
      end

      @new_courses[key] = create_course(attrs, result)
    end

    # 番号が無い講義は、名前だけでは同じ講義かを判断できないので、既存とは突き合わせない
    def same_course_registered?(attrs)
      attrs.course_number.present? && Course.exists?(course_number: attrs.course_number, name: attrs.name)
    end

    def linked_course(attrs, result, line)
      course = Course.find_by(id: attrs.course_id)
      return course if course && course.credits == attrs.credits

      result.errors << if course
                         "#{line}行目(#{attrs.name}): 登録済みの単位(#{course.credits})と取り込みの単位(#{attrs.credits})が違います。"
                       else
                         "#{line}行目(#{attrs.name}): 選ばれた既存の講義が見つかりません。"
                       end
      nil
    end

    def create_course(attrs, result)
      result.created_courses += 1
      Course.create!(course_number: attrs.course_number, name: attrs.name, credits: attrs.credits)
    end

    def save_offering(course, attrs, result, line)
      offering = find_offering(course, attrs)
      if offering.persisted? && offering.course_id != course.id
        return result.errors << "#{line}行目(#{attrs.name}): 講義コード#{attrs.lecture_code}は別の科目で登録済みです。"
      end

      offering.assign_attributes(attrs.offering_attributes.merge(course: course, year: @year,
                                                                 department_id: @department_id))
      return result.unchanged_offerings += 1 unless offering.changed?

      offering.new_record? ? result.created_offerings += 1 : result.updated_offerings += 1
      offering.save!
    end

    # 講義コードは必須なので、引き当てのキーは年度・学期・講義コードの1つだけ。
    # 学科はキーに入れない。講義コードは全学で一意なので、学科を間違えて取り込んだときは、
    # 重複行を作らずに同じ行の学科が直るほうが望ましい。
    def find_offering(_course, attrs)
      CourseOffering.find_or_initialize_by(year: @year, semester: attrs.semester, lecture_code: attrs.lecture_code)
    end

    # 1行ぶんの検証と型変換
    class RowAttributes
      attr_reader :errors, :semester, :lecture_code, :course_number, :name, :credits, :requirement_type,
                  :grade_years, :weekday, :periods, :term_type, :course_id, :register_as_new

      def initialize(row)
        @errors = []
        @semester = row['学期']
        @lecture_code = row['講義コード'].presence
        @course_number = row['科目番号'].presence
        @name = row['科目名']
        @credits = parse_credits(row['単位'])
        @requirement_type = row['必修選択'].presence
        @grade_years = parse_digits(row['受講年次'], '受講年次')
        @weekday = row['曜日'].presence
        @periods = parse_digits(row['時限'], '時限')
        @term_type = row['開講区分'].presence
        @course_id = parse_course_id(row['既存講義ID'])
        @register_as_new = row['新規登録'] == '1'
        validate(row['要確認'])
      end

      def offering_attributes
        { semester: semester, lecture_code: lecture_code, requirement_type: requirement_type,
          grade_years: grade_years, weekday: weekday, periods: periods, term_type: term_type }
      end

      private

      def validate(review)
        errors << "「要確認」が未解消です(#{review})。PDFと見比べて直し、列を空にしてください。" if review.present?
        errors << "学期は#{Values::SEMESTERS.join('か')}にしてください。" unless Values::SEMESTERS.include?(semester)
        errors << '講義コードが空です。' if lecture_code.nil?
        errors << '科目名が空です。' if name.blank?
        errors << '単位は0以上1000未満の整数にしてください。' unless credits
        validate_choice('必修選択', requirement_type, Values::REQUIREMENT_TYPES)
        validate_choice('曜日', weekday, Values::WEEKDAYS)
      end

      def validate_choice(label, value, allowed)
        errors << "#{label}は#{allowed.join('か')}にしてください(空欄可)。" unless value.nil? || allowed.include?(value)
      end

      def parse_course_id(text)
        return if text.blank?

        Integer(text, 10, exception: false) || (errors << '既存講義IDが数字ではありません。' and nil)
      end

      def parse_credits(text)
        credits = Integer(text, 10, exception: false)
        credits if credits && credits >= 0 && credits < 1000
      end

      # 「2・3」「3,4」を[2, 3]に直す。空欄は[]。
      def parse_digits(text, label)
        return [] if text.blank?

        errors << "#{label}は「2・3」のように数字を「・」で区切ってください。" unless text.match?(Values::DIGIT_LIST)
        text.scan(/\d/).map(&:to_i)
      end
    end
  end
end

