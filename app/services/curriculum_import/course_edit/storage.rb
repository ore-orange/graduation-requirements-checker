# frozen_string_literal: true

module CurriculumImport
  class CourseEdit
    # 1科目ぶんの書き込み。document 全体は書き戻さず、jsonb_set / jsonb_insert / #- で、その科目の位置だけを変える。
    #
    # 科目表は484行ある。画面から1科目ずつ確認するたびに document 全体(百数十KB)を読んで書き戻すと、
    # 別の科目を確認した直後の要求が、自分の読み込んだ古い document で、その確認を巻き戻す(取りこぼす)。
    # 位置だけを変える更新なら、他の科目・規則・ページの記録には触れない。呼び出し側は行をロックした中で呼ぶこと
    # (読み取り(ReadPage)・要件表の保存も同じ行をロックして document を書くので、順番に並ぶ)。
    #
    # SQL は固定の文字列だけ。値はすべて束縛で渡す(組み立てない)。
    module Storage
      SET = "document = jsonb_set(document, ARRAY['courses', ?::text], ?::jsonb), updated_at = ?"
      # courses が配列でない下書き(まだ1科目も読んでいない)では、配列を作ってから入れる。
      APPEND = "document = CASE WHEN jsonb_typeof(document->'courses') = 'array' " \
               "THEN jsonb_insert(document, '{courses,-1}', ?::jsonb, true) " \
               "ELSE jsonb_set(document, '{courses}', jsonb_build_array(?::jsonb)) END, updated_at = ?"
      DELETE = "document = document #- ARRAY['courses', ?::text], updated_at = ?"
      # 消した科目の記録を足す。読み直しが同じ行を戻さないための印(DraftMerge が見る)。
      DELETE_RECORDED = "document = jsonb_set(document #- ARRAY['courses', ?::text], '{removed_by_human}', " \
                        "COALESCE(document->'removed_by_human', '[]'::jsonb) || ?::jsonb), updated_at = ?"
      SET_REMOVED = "document = jsonb_set(document, '{removed_by_human}', ?::jsonb), updated_at = ?"

      private

      def write_course(index, course)
        update_document(SET, index, course.to_json)
      end

      def append_course(course)
        json = course.to_json
        update_document(APPEND, json, json)
      end

      # tombstone が nil のときは、記録を足さずに消すだけ(手で足した科目は、読み直しで戻ってこない)。
      def delete_course(index, tombstone)
        return update_document(DELETE, index) unless tombstone

        update_document(DELETE_RECORDED, index, [tombstone].to_json)
      end

      def replace_removed(entries)
        update_document(SET_REMOVED, entries.to_json)
      end

      # update_all は検証もコールバックも通さない。科目1つの位置を書くための SQL なので、それが狙い。
      def update_document(sql, *binds)
        Curriculum.where(id: @curriculum.id).update_all([sql, *binds, Time.current]) # rubocop:disable Rails/SkipsModelValidations
        @curriculum.reload
      end
    end
  end
end

