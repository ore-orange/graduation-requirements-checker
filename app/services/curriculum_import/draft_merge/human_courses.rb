# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # 科目表の読み直しが、人の判断を素通りしないための照合。
    #
    # 科目の同一性は「AI が読んだ科目番号(無ければ名前)」。人が番号や名前を直すと、読み直しの行はどの科目とも一致せず、
    # 同じ行が二重に入る(誤読のまま入った行が、直した科目と並ぶ)。そこで、次の読みを「すでに人の手にある」と見る。
    #  - 確認済みの科目の番号と、直す前の読み(read_as)
    #  - 手で足した科目の番号(足したページが無いので、どのページを読み直しても当たる)
    # 人が消した科目(removed_by_human の kind=course)は、同じページの、同じ読みの行を飛ばす。
    # 同じ番号の行が複数あるとき、消した行の中身の指紋(fingerprint)に合う行だけを飛ばす(先に出る行ではなく)。
    # 指紋の無い記録(読みの中身が分からない)は、番号だけで、消した数だけ飛ばす。
    # 番号が同じで中身が違う行は入れる。ただし、消した記録と番号が同じなので、警告に残す(黙って戻さない)。
    module HumanCourses
      COURSE = 'course'
      # 読み直した行と、残した科目を見比べる欄。判定の数字(単位・区分・必修・承認)と、科目を指す番号・名前。
      COMPARED_FIELDS = %w[number name credits category required requires_approval].freeze

      private

      # 人の手にある科目の { 読み => 科目 }。kept_keys は、このページが前に足して、確認済みのため残した科目の key。
      def held_identities(courses, kept_keys)
        held = courses.select { |course| kept_keys.include?(course['key']) || course['added_by_hand'] }
        held.each_with_object({}) do |course, table|
          [identity(course), course['read_as']].compact.each { |identity| table[identity] ||= course }
        end
      end

      # このページで、人が消した科目の記録(読み直しの1回の中で、飛ばした分を使い切っていく)。
      def removed_course_records
        Array(@document[REMOVED]).grep(Hash).select do |entry|
          entry['kind'] == COURSE && entry['page'] == @page
        end.map(&:dup)
      end

      # 読んだ行を入れずに飛ばすか。人の手にある科目と同じ、または消された読みと同じなら飛ばす。
      # 手で足した科目と同じ行を見つけたときは、人の科目を残したことを警告に出す。
      def human_owned?(row, held, removed)
        identity = identity(row)
        owner = held[identity]
        if owner
          owner['added_by_hand'] ? warn_added_kept(owner, row) : warn_kept_differs(owner, row)
          return true
        end
        removed_row?(row, identity, removed)
      end

      # 消した記録に当たる行か。当たれば記録を1つ使う。同じ番号の記録があるのに、どれにも当たらなければ、警告に残す。
      def removed_row?(row, identity, removed)
        same = removed.select { |entry| entry['identity'] == identity }
        return false if same.empty?

        record = matching_record(same, CourseReading.fingerprint(row))
        unless record
          @warnings << "人が消した科目と同じ番号の行(#{row['number'].presence || row['name']})がありますが、内容が違うため入れました。" \
                       '消した行ではないか、確かめてください。'
          return false
        end
        removed.delete_at(removed.index { |entry| entry.equal?(record) })
        true
      end

      # 指紋が合う記録を先に。指紋の無い記録(読みの中身が分からない)は、番号だけで当たる。
      def matching_record(same, fingerprint)
        same.find { |entry| entry['fingerprint'] == fingerprint } || same.find { |entry| entry['fingerprint'].nil? }
      end

      # 確認済みの科目は残し、読み直した行は入れない。値が違えば、黙って捨てずに警告に残す(規則・章・行と同じ扱い)。
      def warn_kept_differs(owner, row)
        differences = Differences.between(owner.slice(*COMPARED_FIELDS), row.slice(*COMPARED_FIELDS))
        return unless differences.any?

        name = owner['number'].presence || owner['name']
        @warnings << Differences.sentence('科目', name, differences)
      end

      def warn_added_kept(owner, row)
        @warnings << "手で足した科目「#{owner['number']} #{owner['name']}」と同じ行(#{row['number'].presence || row['name']})が" \
                     'このページにありました。手で足した科目を残し、読み直した行は入れていません。'
      end
    end
  end
end

