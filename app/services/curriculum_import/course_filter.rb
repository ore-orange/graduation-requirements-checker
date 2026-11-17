# frozen_string_literal: true

module CurriculumImport
  # 便覧に残す科目を決める。科目番号から区分が決まる科目は、番号だけで区分が引けるので、科目表に持たない
  # (484件すべてではなく、番号から決まらない科目だけを人が確認する)。
  #
  # 落とすのは、次のすべてが当てはまる科目だけ。迷ったら残す(落とすと、人が見る機会が無くなるため)。
  # - 科目番号があり、区分の number_patterns で区分が決まる。
  # - 読み(category)が、番号から決まる区分と一致する。違う読みは、AI か人が何かを見ている。
  # - 必修・役割・承認・選べない・要確認の理由のどれも持たない。判定が個別に見る科目だから。
  # - 人が確認していない、人が手で足していない。このアプリは「人が触ったものは読み直しでも外さない」を守るので、
  #   絞り込みだけ逆向きにはしない。
  class CourseFilter
    # 区分の内訳に使う。壊れた文書でも例外にしないため、Catalogue は使わない(NumberPatterns を参照)。
    def initialize(document)
      categories = document.is_a?(Hash) ? Array(document['categories']).grep(Hash) : []
      @categories = categories
      @patterns = NumberPatterns.new(categories)
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
        course['selectable'] != true || course['review_reason'].present?
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

