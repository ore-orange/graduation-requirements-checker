# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 科目表の突き合わせ。設計書 §4 の 1(番号の重複)・6(区分の食い違い)・7(出典)・8・9(番号の欠け)。
    #
    # 科目に review_reason が書いてあるときは、番号や単位の欠けを問題にしない。理由が学生の画面に
    # 「要確認」として出るので、黙って捨てられてはいない(2024年度の「知能情報特別講義Ⅴ・Ⅵ」がこれ)。
    # この検査が見つけたいのは、誰にも知らされないまま欠けている科目のほう。
    class CourseChecks < Checks
      def run
        duplicate_keys
        duplicate_numbers
        input.courses.each_with_index { |course, index| check_course(course, index) }
        mismatched_categories
      end

      private

      # key は科目の同一性そのもの。空だと判定が科目を引けず、重複すると Catalogue は後ろの1件だけを覚え、
      # 前の科目の単位は黙って消える。
      def duplicate_keys
        input.courses.each_with_index do |course, index|
          findings.blocking(:course, target_of(course, index), '科目に key がありません') unless text?(course['key'])
        end
        input.courses.pluck('key').select { |key| text?(key) }.tally.each do |key, count|
          next if count == 1

          findings.blocking(:course, key, "key「#{key}」の科目が#{count}件あります。判定は後ろの1件しか使わず、前の科目の単位は数えられません。")
        end
      end

      # 科目番号の重複は、公開すると Catalogue が読み込みを拒む。画面に出る理由を、公開の前に言う。
      def duplicate_numbers
        numbered = input.courses.select { |course| text?(course['number']) }
        numbered.group_by { |course| course['number'] }.each do |number, group|
          next if group.size == 1

          findings.blocking(:course, number, "同じ科目番号「#{number}」の科目が#{group.size}件あります(#{names(group)})。" \
                                             '公開すると便覧を読み込めません。重複した行のどちらかを外してください。')
        end
        notation_duplicates(numbered)
      end

      # 全角・空白の違いだけの同じ番号。Catalogue は別の番号として通すが、人には同じ科目に見える。
      def notation_duplicates(numbered)
        numbered.group_by { |course| CourseNumber.normalize(course['number']) }.each do |normalized, group|
          spellings = group.pluck('number').uniq
          next if spellings.one?

          findings.warning(:course, normalized, "科目番号の綴りが違うだけの同じ番号があります(#{spellings.join('、')})。同じ科目の重複ではないか確かめてください。")
        end
      end

      def check_course(course, index)
        target = target_of(course, index)
        label = label_of(course)
        explained = text?(course['review_reason'])
        number_problem(course, target, label) unless explained
        category_problem(course, target, label) unless explained
        credits_problem(course, target, label) unless explained
        return if text?(course['source_page'])

        findings.warning(:course, target, "#{label}は出典(source_page)がありません。便覧のどのページから読んだか分からず、確かめられません。")
      end

      def number_problem(course, target, label)
        number = course['number']
        if !text?(number)
          findings.warning(:course, target, "#{label}は、分類表にあって提供科目表に行がない科目です(科目番号が空)。" \
                                            '番号が読めなかっただけかもしれません。ページを読み直すか、番号を埋めてください。')
        elsif CourseNumber.prefix(number).nil? && prefix_dependent?(course['category'])
          findings.warning(:course, target, "#{label}の科目番号「#{number}」を、接頭辞と数字に分けて読めません。" \
                                            'この区分の規則は科目番号の接頭辞で数えるので、この科目はグループにも除外にも当たりません。')
        end
      end

      # 科目番号を読めなくても、その区分に接頭辞で数える規則が無ければ、判定は変わらない。2024年度の「人27-1」のような
      # 枝番つきの番号は読めないが、人文系には接頭辞の規則が無いので、問題にしない(全部に警告すると、見るべき警告が埋もれる)。
      def prefix_dependent?(category)
        @prefix_dependent ||= begin
          grouped = input.well_formed_nodes_of('grouped_max').select { |node| number_grouping?(node.rule['group_by']) }
          excluded = input.well_formed_nodes_of('exclude').select { |node| node.rule.key?('number_prefix') }
          (grouped + excluded).map { |node| node.rule['category'] }
        end
        @prefix_dependent.include?(category)
      end

      def number_grouping?(group_by)
        RuleShape::GROUP_BY_NUMBER.include?(group_by)
      end

      # 区分が便覧に無い科目は、どの行にも出ず、どの規則にも数えられない。「単位が反映されない」そのもの。
      def category_problem(course, target, label)
        category = course['category']
        return if input.category_keys.include?(category)

        findings.blocking(:course, target, "#{label}の区分「#{category}」が categories にありません。" \
                                           'この科目の単位はどの区分にも数えられず、画面のどの行にも出てきません。')
      end

      def credits_problem(course, target, label)
        credits = decimal(course['credits'])
        return if credits&.positive?

        findings.warning(:course, target, "#{label}の単位数(#{course['credits'].inspect})が読めていないか、0です。")
      end

      # 番号から推定した区分と、読み取った区分が違う科目。人が確認済み(confirmed)にした科目は、見たうえでの判断なので出さない。
      def mismatched_categories
        CategoryInference.new(input.courses).mismatches.each do |mismatch|
          courses = input.courses.select do |course|
            course['number'] == mismatch[:number] && course['category'] == mismatch[:read]
          end
          next if courses.empty? || courses.all? { |course| course['confirmed'] == true }

          findings.warning(:course, target_of(courses.first, input.courses.index do |candidate|
            candidate.equal?(courses.first)
          end),
                           mismatch_reason(courses.first, mismatch))
        end
      end

      def mismatch_reason(course, mismatch)
        "#{label_of(course)}は区分「#{input.category_label(mismatch[:read])}」と読まれていますが、同じ番号帯の他の科目は" \
          "区分「#{input.category_label(mismatch[:inferred])}」です。区分の取り違えでないか確かめてください(番号の付け方に例外はあります)。"
      end

      def target_of(course, index)
        text?(course['key']) ? course['key'] : "courses[#{index + 1}]"
      end

      def label_of(course)
        number = course['number'].to_s.strip
        name = course['name'].to_s.strip
        [number, ("「#{name}」" if name.present?)].compact_blank.join.presence || '名前のない科目'
      end

      def names(group)
        group.map { |course| course['name'].to_s }.join('、')
      end
    end
  end
end

