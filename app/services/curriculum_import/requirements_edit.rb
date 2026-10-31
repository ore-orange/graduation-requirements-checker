# frozen_string_literal: true

module CurriculumImport
  # 確認画面で人が直した「要件表」(区分・規則・表示の章と行・総単位・注釈の扱い)を、下書きの document に入れる。
  #
  # 守るべきことは3つ。
  #
  # 1. 直したものは、読み直しから守る。直した規則・章・行・小計・区分には confirmed を付ける(DraftMerge が、読み直しで
  #    外さず、入れ直さず、読み直した側の値を採らない)。消したものは document['removed_by_human'] に残し、戻さない。
  #    総単位は値なので印を持てない。そのページの記録(contributed の total_credits)を人の印に替えて、読み直しの対象から外す。
  #    直していないものには印を付けない。画面は全部を送ってくるので、値が変わったものだけを「直した」とする。
  #    並べ替えは、位置が変わったものを直したとする(並びを元に戻すのは、AI の読みで足された並びではなく人の並び)。
  # 2. 送られなかったものは消さない。置き換えるのは、送られた項目の値と並びだけ。消すのは、消すと明示されたものだけ
  #    (欠けた送信で規則が黙って落ちると、その要件が判定から消える)。
  # 3. 画面を開いてから読み取りなどで中身が変わっていたら、何も変えない(revision。送られなければ受けない)。古い画面の値で、
  #    あとから読み取った規則を消してしまわないため。
  #
  # エラーが1つでもあれば、何も保存しない。エラーは全部集め、どの項目の問題かを持つ(画面が、入力を残したまま項目の下に出す)。
  class RequirementsEdit
    include Bookkeeping
    include Coercion
    include RuleEditing
    include DisplayEditing
    include Additions

    # どの項目(kind と id)の、どんな問題か。kind が nil なら、項目に結びつかない問題。
    Problem = Struct.new(:message, :kind, :id)

    # edited は、直したものの数(画面の「保存しました」に出す)。touched は、値を変えた・問題があった項目の [kind, id]。
    # stale は、画面を開いたあとに中身が変わっていたため断ったとき。
    Result = Struct.new(:problems, :edited, :notes, :touched, :stale, keyword_init: true) do
      def ok? = problems.empty?
      def errors = problems.map(&:message)
    end

    # 画面が開いたときの中身の指紋。送り返された値と比べる。
    TRACKED = %w[categories rules display approval_notes annotation_decisions removed_by_human].freeze
    GROUP_FIELDS = { 'title' => :text, 'required_credits' => :number, 'check_id' => :text }.freeze
    ROW_FIELDS = { 'name' => :text, 'subtitle' => :text, 'required_credits' => :number, 'required_label' => :text,
                   'categories' => :set, 'check_ids' => :list, 'credits_from_check' => :flag }.freeze
    SUBTOTAL_FIELDS = { 'name' => :text, 'required_credits' => :number, 'row_ids' => :list,
                        'check_ids' => :list }.freeze
    CATEGORY_FIELDS = { 'label' => :text, 'counts_toward_total' => :flag }.freeze
    RULE_COMMON_FIELDS = { 'label' => :text, 'detail' => :text }.freeze
    # 規則の型ごとの欄(Validation::Input::FIELD_KINDS)のうち、フォームの1つの欄で直せるもの。それ以外は JSON で直す。
    RULE_FIELD_KINDS = { number: :number, count: :count, keys: :set, text: :text }.freeze
    # FIELD_KINDS に無いが、判定の数字を決める欄。cap の上限(credits)を読み違えると、算入してはいけない単位が数えられる。
    # exclude の接頭辞(number_prefix)は、読み違えると何にも当たらず、何も除外しない。欄が無い(区分全体)と空は同じ意味なので、
    # 空にしたときは欄ごと消す(欄があって空だと、読み込みが拒む)。
    RULE_EXTRA_FIELDS = { 'cap' => { 'credits' => :number }, 'exclude' => { 'number_prefix' => :optional_text } }.freeze
    # エラーの文で欄を呼ぶ名前(画面の欄の名前と同じ)。
    FIELD_LABELS = { 'label' => '名前', 'name' => '名前', 'detail' => '注記', 'title' => '章の名前', 'subtitle' => '副題',
                     'required_credits' => '必要単位', 'required_label' => '必要単位が空のときの表示',
                     'expected_course_count' => '必修の科目数', 'categories' => '数える区分',
                     'required_categories' => '必修の区分', 'category' => '区分', 'group_by' => 'グループの分け方',
                     'reason' => '算入しない理由', 'review_note' => '要確認の理由', 'check_id' => '確認する規則', 'check_ids' => '確認する規則',
                     'row_ids' => '数える行', 'credits_from_check' => '単位を確認する規則から取るか',
                     'counts_toward_total' => '卒業の総単位に数えるか', 'credits' => '算入の上限(単位)',
                     'number_prefix' => '科目番号の接頭辞' }.freeze
    KIND_NAMES = { 'rule' => '規則', 'group' => '章', 'row' => '行', 'subtotal' => '小計', 'category' => '区分' }.freeze
    CONTRIBUTED_FIELD = { 'rule' => 'rules', 'group' => 'groups', 'subtotal' => 'subtotals' }.freeze
    ORIGIN_FIELD = { 'rule' => 'rules', 'group' => 'groups', 'subtotal' => 'subtotals', 'row' => 'rows' }.freeze

    # 科目を消した記録(kind=course)は数えない。科目表の確認画面が足す記録で、要件表の画面の中身ではない。
    # 数えると、科目を1つ消しただけで、開いたままの要件表の画面が「中身が変わった」と断られる。
    def self.revision(document)
      document = {} unless document.is_a?(Hash)
      tracked = document.slice(*TRACKED)
      removed = tracked[DraftMerge::REMOVED]
      if removed.is_a?(Array)
        removed = removed.reject { |entry| entry.is_a?(Hash) && entry['kind'] == DraftMerge::HumanCourses::COURSE }
        removed.empty? ? tracked.delete(DraftMerge::REMOVED) : tracked[DraftMerge::REMOVED] = removed
      end
      Digest::SHA256.hexdigest(JSON.generate(tracked))
    end

    # 規則の型で、フォームの欄で直せる欄の { 欄 => 種類 }。画面とここで同じ表を使う。
    def self.rule_fields(rule)
      type = rule['type']
      adjustment = GraduationAssessment::Rules::ADJUSTMENTS.key?(type)
      fields = adjustment ? { 'detail' => :text } : RULE_COMMON_FIELDS.dup
      (Validation::Input::FIELD_KINDS[type] || {}).each do |field, kind|
        fields[field] = RULE_FIELD_KINDS.fetch(kind) if RULE_FIELD_KINDS.key?(kind)
      end
      fields.merge(RULE_EXTRA_FIELDS.fetch(type, {}))
    end

    def initialize(curriculum, params)
      @curriculum = curriculum
      @params = params.to_h.with_indifferent_access
      @document = curriculum.document.deep_dup
      @pages = curriculum.pages.deep_dup
      @problems = []
      @touched = []
      @edited = 0
      @notes = []
      @counted = []
    end

    # 行をロックした中で呼ぶこと(読み取りと同時に走っても、最新の document の上で直す)。
    def call
      return failure('この下書きの形が読めません(document がハッシュではありません)。') unless @document.is_a?(Hash)
      return failure(missing_revision_message) if @params[:revision].blank?
      return failure(stale_message, stale: true) if @params[:revision] != self.class.revision(@document)

      apply_sections
      return result(0) if @problems.any?
      return result(0, ['変えた箇所はありませんでした。']) if no_changes?

      @curriculum.update!(document: @document, pages: @pages)
      result(@edited, @notes)
    end

    private

    def result(edited, notes = [])
      Result.new(problems: @problems, edited: edited, notes: notes, touched: @touched.uniq)
    end

    def failure(message, stale: false)
      Result.new(problems: [Problem.new(message)], edited: 0, notes: [], touched: [], stale: stale)
    end

    def stale_message
      'この画面を開いたあとに、要件表の中身が変わっています(読み取りや、ほかの操作)。何も保存していません。' \
        '画面を開き直して、もう一度直してください。'
    end

    def missing_revision_message
      '画面を開いた時点の指紋(revision)が送られていないため、保存しません。要件表の画面から保存してください。'
    end

    def no_changes?
      @document == @curriculum.document && @pages == @curriculum.pages
    end

    def apply_sections
      edit_categories
      edit_rules
      add_new_rule
      edit_display
      add_new_group
      add_new_row
      decide_annotations
      remove_approval_note
    end

    # ---- 区分 ----

    def edit_categories
      entries = entries(@params[:categories], 'categories') or return
      categories = list_of(@document, 'categories') or return

      entries.each do |entry|
        key = entry[:key] || entry[:id]
        category = categories.find { |item| item['key'] == key }
        next error("区分「#{key}」は下書きにありません。", 'category', key) unless category

        mark(category, assign(category, entry, CATEGORY_FIELDS, 'category', category['key']).any?)
      end
    end

    # ---- 注釈 ----

    def decide_annotations
      decisions = @params[:annotations]
      return if decisions.nil?
      return error('注釈の扱いの形が違います。') unless decisions.is_a?(Hash)

      decisions.each { |id, decision| decide_annotation(id.to_s, decision) }
    end

    def decide_annotation(id, decision)
      disposition = decision.is_a?(Hash) ? decision[:disposition].to_s : ''
      return error('注釈の扱いを選んでください。', 'annotation', id) if disposition.blank?

      problem = Annotations.decide(@document, @pages, id, disposition, category: decision[:category].to_s.presence)
      problem ? error(problem, 'annotation', id) : @edited += 1
    end

    # 承認の注記を外す。外した注記は、読み直しで同じページの注記として戻らないよう、消したものとして記録する。
    def remove_approval_note
      id = @params[:remove_approval_note].to_s
      return if id.blank?

      problem = Annotations.remove_note(@document, id)
      return error(problem, 'annotation', id) if problem

      @edited += 1
      @notes << '承認の注記を外しました。読み直しても戻りません。'
    end
  end
end

