# frozen_string_literal: true

module TimetableImport
  # 人が確認した行(日本語の見出しをキーにしたハッシュ)を courses に保存する。
  # 1行がそのまま1レコードになる。1つでもエラーがあれば何も保存しない。
  # apply: false(既定)ではトランザクションを巻き戻し、保存した場合と同じ件数だけを返す(dry-run)。
  #
  # 引き当てのキーは年度・学期・講義コードの3つだけ。講義コードは必須なので、これで1件に定まる。
  # 同じ名前・番号の講義が既にあっても突き合わせはしない(別の年度・学期の同じ科目は別の行)。
  # 便覧由来の科目は講義コードを持たないので、引き当てに当たることはない。
  #
  # 学科はキーに入れない。講義コードは全学で一意なので、学科を間違えて取り込んだときは、
  # 重複行を作らずに同じ行の学科が直るほうが望ましい。
  class Importer
    Result = Struct.new(:errors, :created, :updated, :unchanged, :applied, keyword_init: true) do
      def ok? = errors.empty?
    end

    # 年度と学科は行ごとではなく取り込み全体で1つなので、行のハッシュには入れず引数で受ける。
    def initialize(rows, year:, department_id:)
      @rows = rows
      @year = year
      @department_id = department_id
    end

    def call(apply: false)
      result = Result.new(errors: [], created: 0, updated: 0, unchanged: 0, applied: false)
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

      save_course(attrs, result)
    end

    def save_course(attrs, result)
      course = Course.find_or_initialize_by(year: @year, semester: attrs.semester,
                                            lecture_code: attrs.lecture_code)
      course.assign_attributes(attrs.course_attributes.merge(department_id: @department_id))
      return result.unchanged += 1 unless course.changed?

      course.new_record? ? result.created += 1 : result.updated += 1
      course.save!
    end

    # 1行ぶんの検証と型変換
    class RowAttributes
      attr_reader :errors, :semester, :lecture_code, :course_number, :name, :credits, :requirement_type,
                  :grade_years, :weekday, :periods, :term_type

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
        validate(row['要確認'])
      end

      def course_attributes
        { course_number: course_number, name: name, credits: credits, semester: semester,
          lecture_code: lecture_code, requirement_type: requirement_type, grade_years: grade_years,
          weekday: weekday, periods: periods, term_type: term_type }
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

