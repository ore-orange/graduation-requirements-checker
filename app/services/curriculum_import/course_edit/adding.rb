# frozen_string_literal: true

module CurriculumImport
  class CourseEdit
    # 読み落とした科目を、手で足す。足した科目は確認済みで、読み直しでは消えず、同じ番号の行も二重に入らない(DraftMerge)。
    module Adding
      private

      def add_course(document)
        courses = document['courses'].is_a?(Array) ? document['courses'] : []
        values = ADDED_REQUIRED.index_with { |field| added_value(field, document, courses) }
        return result if @problems.any?

        @course = build_added(courses, values)
        @key = @course['key']
        append_course(@course)
        forget_removal(document, @course)
        result(ADDED_REQUIRED, ["#{label}を足しました。確認済みの科目として残り、読み直しでは上書きしません。"])
      end

      def added_value(field, document, courses)
        value = coerce(@params[field], FIELDS.fetch(field), "科目の#{LABELS.fetch(field)}")
        value == :invalid ? value : check(field, value, document, courses)
      end

      def build_added(courses, values)
        { 'key' => unused_key(values['number'], courses), 'number' => values['number'], 'name' => values['name'],
          'credits' => values['credits'], 'category' => values['category'], 'required' => flag_given?('required'),
          'language' => nil, 'roles' => [], 'source' => "handbook_#{@curriculum.admission_year}",
          'source_page' => ADDED_SOURCE_PAGE, 'review_reason' => nil,
          'requires_approval' => flag_given?('requires_approval'),
          'selectable' => !@params.key?('selectable') || flag_given?('selectable'), 'confirmed' => true,
          ADDED_BY_HAND => true }
      end

      # 手で足すときの、はい/いいえの欄。送られなければ「いいえ」(足す科目の既定)。
      def flag_given?(field)
        value = @params.key?(field) ? coerce(@params[field], :flag, "科目の#{LABELS.fetch(field)}") : false
        value == true
      end

      def unused_key(number, courses)
        taken = courses.grep(Hash).pluck('key')
        base = "course_#{number}"
        return base unless taken.include?(base)

        (2..).lazy.map { |n| "#{base}_hand#{n}" }.find { |candidate| taken.exclude?(candidate) }
      end

      # 足した科目と同じ読みの、消した記録は外す(人が戻した)。
      def forget_removal(document, course)
        entries = Array(document['removed_by_human'])
        kept = entries.reject do |entry|
          entry.is_a?(Hash) && entry['kind'] == 'course' && entry['identity'] == identity(course)
        end
        replace_removed(kept) if kept.size != entries.size
      end
    end
  end
end

