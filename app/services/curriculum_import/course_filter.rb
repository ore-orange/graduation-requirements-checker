# frozen_string_literal: true

module CurriculumImport
  # 便覧に残す科目を決める。科目番号から区分が決まる科目は、番号だけで区分が引けるので、科目表に持たない
  # (484件すべてではなく、番号から決まらない科目だけを人が確認する)。
  #
  # 落とすのは、次のすべてが当てはまる科目だけ。迷ったら残す(落とすと、人が見る機会が無くなるため)。
  # - 科目番号があり、区分の number_patterns で区分が決まる。
  # - 読み(category)が、番号から決まる区分と一致する。違う読みは、AI か人が何かを見ている。
  # - 必修・役割・承認・選べない・要確認の理由のどれも持たない。判定が個別に見る科目だから。
  # - 便覧の規則が欄で分ける科目でない。その欄の値は番号から決まらないので、外すと値ごと失われる(grouped_field? を参照)。
  # - 人が確認していない、人が手で足していない。このアプリは「人が触ったものは読み直しでも外さない」を守るので、
  #   絞り込みだけ逆向きにはしない。
  class CourseFilter
    # grouped_max が「科目の欄」で分けるときの印。判定と同じ語を使う(綴りがずれたら grouped_field? が効かなくなる)。
    FIELD_GROUP = GraduationAssessment::Ledger::FIELD_GROUP
    # 入れ子の規則を持つ欄。any_of の options、all_of の conditions。
    NESTED_RULES = GraduationAssessment::Catalogue::NESTED_RULES

    # 区分の内訳に使う。壊れた文書でも例外にしないため、Catalogue は使わない(NumberPatterns を参照)。
    def initialize(document)
      document = {} unless document.is_a?(Hash)
      categories = Array(document['categories']).grep(Hash)
      @categories = categories
      @patterns = NumberPatterns.new(categories)
      @grouped_fields = grouped_fields(document['rules'])
    end

    def keep?(course)
      return true if CourseEdit.confirmed?(course) || course['added_by_hand'] == true
      return true if special?(course)

      decided = @patterns.category_for(course['number'])
      decided.nil? || decided != course['category']
    end

    # [残す科目, 落とす科目]。順序は入力のまま。
    def partition(courses)
      courses.partition { |course| keep?(course) }
    end

    # 落とした科目を人に知らせる1文。内訳は和名で、件数の多い順。同数は categories の並び順(出力が実行ごとに揺れないように)。
    def drop_summary(dropped)
      return '' if dropped.empty?

      "番号から区分が決まる科目#{dropped.size}件は、登録しませんでした(#{breakdown(dropped)})。" \
        '区分の科目番号のパターンで数えます。'
    end

    private

    # 判定が個別に見る科目。選べるかは、欄が無いときも「選べる」と言い切らず残す(CoursesReview と同じ読み方)。
    def special?(course)
      course['required'] == true || Array(course['roles']).any? || course['requires_approval'] == true ||
        course['selectable'] != true || course['review_reason'].present? || grouped_field?(course)
    end

    # 便覧の規則が欄で分ける科目。その欄に値があれば残す。
    #
    # grouped_max は区分の単位を欄の値ごとに分けて数える(「同じ一外国語で4単位」)。番号から決まるのは区分までで、
    # 欄の値は決まらない。外すと、判定は科目番号から区分だけを復元した合成科目を見るので、欄が空のまま
    # 「グループが未確認」になり、充足とも不足とも言えなくなる。欄の値は科目表にしか無いので、残すしかない。
    #
    # 欄の名前はコードに持たない。便覧ごとに違うので、文書の規則から読む(便覧に grouped_max が無ければ空)。
    def grouped_field?(course)
      @grouped_fields.any? { |field| course[field].present? }
    end

    # grouped_max が group_by: "field:<欄名>" で分けている欄の名前。入れ子の規則もたどる。
    # 読めない規則は黙って飛ばす(取り込み途中の下書きは壊れていることがあり、絞り込みがそこで止まってはいけない)。
    def grouped_fields(rules)
      Array(rules).grep(Hash).flat_map { |rule| fields_in(rule) }.uniq
    end

    def fields_in(rule)
      nested = NESTED_RULES.flat_map { |key| Array(rule[key]).grep(Hash).flat_map { |child| fields_in(child) } }
      field = field_name(rule)
      field ? nested.unshift(field) : nested
    end

    def field_name(rule)
      group_by = rule['group_by']
      return unless rule['type'] == 'grouped_max' && group_by.is_a?(String) && group_by.start_with?(FIELD_GROUP)

      group_by.delete_prefix(FIELD_GROUP).presence
    end

    def breakdown(dropped)
      order = @categories.pluck('key')
      counts = dropped.pluck('category').tally
      counts.sort_by { |key, count| [-count, order.index(key) || order.size] }
            .map { |key, count| "#{label_for(key)}#{count}件" }.join('、')
    end

    def label_for(key)
      @categories.find { |category| category['key'] == key }&.dig('label') || key.to_s
    end
  end
end

