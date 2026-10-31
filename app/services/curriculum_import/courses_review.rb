# frozen_string_literal: true

module CurriculumImport
  # 科目表の確認画面が見せるもの。AI が読んだ科目を、人が PDF と見比べて直すために並べる。
  #
  # 誤読を「見える」ようにするのが目的。判定の単位を水増しする値(単位・区分・選べるか・承認が要るか・総単位に数えるか)は、
  # 開かなくても目に入る場所に出す(画面側)。ここは、どの科目を先に見るか(最初に見る科目)と、区分ごとのまとめ方を決める。
  #
  # 「最初に見る科目」は、番号帯の他の科目と区分が食い違う科目(CategoryInference)・突き合わせ(Validation)が
  # 指摘した科目・AI が要確認の理由を付けた科目。食い違いは「AI が誤り」の断定ではなく、人が見る印
  # (2024年度の便覧では、必修が選択の番号帯に入る2科目が正しいまま食い違う)。人が確認した科目は、食い違いも要確認の理由も
  # 見たうえでの判断なので、ここには出さない。公開を止める指摘だけは、確認しても残す(直るまで見せる)。
  #
  # 要件表の確認画面(RequirementsReview)の上に作る。突き合わせは画面を開くたびに走るので、結果を共有する(二度走らせない)。
  class CoursesReview
    # reasons は、最初に見る理由(:blocking・:mismatch・:finding・:reason)。inferred は、番号帯から推定した区分(食い違うときだけ)。
    Row = Struct.new(:course, :index, :findings, :inferred, :reasons, keyword_init: true) do
      def key = course['key']

      def confirmed? = course['confirmed'] == true

      def look_first? = reasons.any?
    end
    Section = Struct.new(:key, :title, :total, :required_credits, :counted, :selectable, :unselectable, :rows,
                         keyword_init: true)
    # 区分の見出しに出す名前に使えない科目(区分が便覧に無い・読めない)をまとめる節。
    UNKNOWN_KEY = '_unknown'

    attr_reader :review, :problems

    delegate :curriculum, :category_label, :category_keys, :courses, to: :review

    # editing は、送信が直そうとした科目の key(足そうとしたときは :add)。submission は、その送信の入力。
    def initialize(review, submission: nil, problems: [], editing: nil)
      @review = review
      @submission = submission
      @problems = problems
      @editing = editing
    end

    # 科目が1つでもあるか、科目表のページを読み終えていれば、確認する。
    def started?
      courses.any? || curriculum.pages.any? { |page| page['kind'] == 'courses' && page['status'] == 'read' }
    end

    def total = courses.size

    def confirmed_count = courses.count { |course| course['confirmed'] == true }

    def blocking_count = rows.count { |row| row.reasons.include?(:blocking) }

    # 先に見る科目の数。人が確認していない食い違いなど。
    def look_first_count = first_look.size

    def rows
      @rows ||= courses.each_with_index.map { |course, index| build_row(course, index) }
    end

    # 最初に見る科目。公開を止める指摘 → 食い違い → ほかの指摘・要確認の理由の順(同じ重さなら便覧の並び)。
    def first_look
      @first_look ||= rows.select(&:look_first?).sort_by { |row| [priority(row), row.index] }
    end

    # 区分ごとの節。最初に見る科目は、その節には出さず(二重に出さない)、見出しの科目数には数える。
    def sections
      @sections ||= begin
        shown = rows.reject(&:look_first?).group_by { |row| row.course['category'] }
        known = category_keys.map { |key| section(key, category_label(key), all_in(key), shown[key].to_a) }
        known + [unknown_section(shown)].compact
      end
    end

    def uncounted?(category) = review.uncounted_category_keys.include?(category)

    def category_options = category_keys.map { |key| [category_label(key), key] }

    def problems_for(key) = problems.select { |problem| problem.id == key.to_s }

    def problems? = problems.any?

    # 入力欄の値。保存できなかった送信の入力が、その科目のものなら残す(1つの打ち間違いで、打った全部を失わせない)。
    def field_value(key, name, default)
      mine?(key) && @submission.key?(name) ? @submission.value(name) : default
    end

    # チェックの箱の状態。送信がその科目のものなら、送られた箱だけが入っている。
    def field_checked?(key, name, default)
      mine?(key) ? @submission.value(name).then { |value| CourseEdit::TRUE_VALUES.include?(value) } : default
    end

    # 保存できなかった科目(と、足そうとした科目)の編集欄は、開いたままにする。
    def open?(key) = @editing.to_s == key.to_s && @editing.present?

    # 画面を開いたときの、その科目の指紋。送り返され、開いたあとに変わっていないかを確かめる。
    def revision(course) = CourseEdit.fingerprint(course)

    # PDFペインに並べるページ。科目表のページで、画像があるもの。index はペインの中の位置(1始まり)。
    def panes
      @panes ||= begin
        pages = curriculum.pages.select { |page| page['kind'] == 'courses' && curriculum.page_image_path(page['page']) }
        pages.each_with_index.map { |page, index| { number: page['page'], index: index + 1 } }
      end
    end

    def pane_width = panes.first && curriculum.page_image_width(panes.first[:number])

    # 科目の出典(PDF3ページなど)のうち、ペインで開けるページ。[ページ番号, ペインの位置] の並び。
    def jump_targets(course)
      course['source_page'].to_s.scan(/\d+/).filter_map do |digits|
        pane = panes.find { |entry| entry[:number] == digits.to_i }
        [pane[:number], pane[:index]] if pane
      end.uniq
    end

    private

    def mine?(key)
      @submission && @editing.to_s == key.to_s && @editing.present?
    end

    def build_row(course, index)
      targets = [course['key'].to_s, course['number'].to_s, "courses[#{index + 1}]"]
      findings = findings_by_target.values_at(*targets).flatten.compact.uniq
      inferred = inferred_for(course)
      Row.new(course: course, index: index, findings: findings, inferred: inferred,
              reasons: reasons_for(course, findings, inferred))
    end

    def reasons_for(course, findings, inferred)
      reasons = []
      reasons << :blocking if findings.any? { |finding| finding[:blocking] }
      return reasons if course['confirmed'] == true

      reasons << :mismatch if inferred
      reasons << :finding if findings.any?
      reasons << :reason if course['review_reason'].present?
      reasons
    end

    def priority(row)
      return 0 if row.reasons.include?(:blocking)

      row.inferred ? 1 : 2
    end

    # 科目の key・番号(重複の指摘の宛先)・「courses[n]」(key の無い科目)に当たる指摘。
    def findings_by_target
      @findings_by_target ||= review.findings.select { |finding| finding[:scope] == :course }
                                    .group_by { |finding| finding[:target] }
    end

    # 番号帯から推定した区分が、読み取った区分と違う科目。人が確認した科目は、見たうえでの判断なので出さない。
    def inferred_for(course)
      return if course['confirmed'] == true

      mismatch = mismatches[course['number']]
      mismatch[:inferred] if mismatch && mismatch[:read] == course['category']
    end

    def mismatches
      @mismatches ||= CategoryInference.new(courses).mismatches.index_by { |mismatch| mismatch[:number] }
    end

    def all_in(key) = courses.select { |course| course['category'] == key }

    def section(key, title, members, shown)
      Section.new(key: key, title: title, total: members.size, required_credits: required_credits(members),
                  counted: !uncounted?(key), selectable: members.count { |course| course['selectable'] == true },
                  unselectable: members.count { |course| course['selectable'] != true }, rows: shown)
    end

    def unknown_section(shown)
      rows = shown.except(*category_keys).values.flatten
      return if rows.empty?

      section(UNKNOWN_KEY, '区分が便覧に無い・読めない科目', rows.pluck(:course), rows)
    end

    # 必修の科目の単位の合計。数でない単位は数えない(画面は、読めない値を数えたことにしない)。
    def required_credits(members)
      members.sum do |course|
        course['required'] == true && course['credits'].is_a?(Numeric) ? course['credits'].to_d : 0
      end
    end
  end
end

