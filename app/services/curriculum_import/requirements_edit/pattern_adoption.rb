# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 区分の科目番号パターンの候補(CategoryInference#suggestions)を、人が押して採用する。
    #
    # 採用は、候補を number_patterns に入れ、区分に人の印を付け、その番号帯に当たる科目を科目表から外す。
    # 外すのは確認済みの科目も含む(人が押した操作なので。押す前に画面が件数を見せている)。
    #
    # 走るのは apply_sections の最後。先に走ると、同じ保存で人が直した区分・規則の値を踏む。
    # adopt_patterns が送られない・空・オフのときは、文書に何も書かない。
    module PatternAdoption
      private

      def adopt_patterns
        keys = adopted_keys or return
        return if keys.empty?

        categories = list_of(@document, 'categories') or return
        suggestions = CategoryInference.new(@document['courses']).suggestions(categories)
        adopted = keys.select { |key| adopt_one(categories, suggestions, key) }
        return if adopted.empty?

        prune_adopted(adopted)
      end

      # 押された区分のキー。送られなければ空。形が違えば問題にして nil。
      def adopted_keys
        value = @params[:adopt_patterns]
        return [] if value.blank?
        return error('adopt_patterns の形が違います。') unless value.is_a?(Hash)

        value.filter_map { |key, flag| key.to_s if Bookkeeping::TRUE_VALUES.include?(flag) }
      end

      # 候補を区分に入れる。候補が無い(パターンを既に持つ・区分が無い)なら問題にする。入れたら true。
      def adopt_one(categories, suggestions, key)
        category = categories.find { |item| item['key'] == key }
        return error("区分「#{key}」は下書きにありません。", 'category', key) unless category

        patterns = suggestions[key]
        unless patterns
          return error("区分「#{category['label']}」には、採用できる科目番号の候補がありません" \
                       '(既にパターンがあるか、候補にする根拠が足りません)。', 'category', key)
        end

        category['number_patterns'] = patterns
        @touched << ['category', key]
        mark(category, true)
        true
      end

      def prune_adopted(keys)
        dropped = CoursePrune.call(@document, drop_confirmed: true, only: keys)
        labels = @document['categories'].select { |item| keys.include?(item['key']) }.pluck('label').join('・')
        confirmed = dropped.count { |course| CourseEdit.confirmed?(course) }
        @notes.unshift("科目番号のパターンを採用しました(#{labels})。科目表から#{dropped.size}件を外しました" \
                       "(うち確認済み#{confirmed}件)。")
      end
    end
  end
end

