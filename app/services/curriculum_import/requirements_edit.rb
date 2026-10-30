# frozen_string_literal: true

module CurriculumImport
  # 確認画面で人が直した「要件表」(区分・規則・表示の章と行・総単位・注釈の扱い)を、下書きの document に入れる。
  #
  # 守るべきことは3つ。
  #
  # 1. 直したものは、読み直しから守る。直した規則・章・行・小計・区分には confirmed を付ける(DraftMerge が、読み直しで
  #    外さず、入れ直さず、読み直した側の値を採らない)。消したものは document['removed_by_human'] に残し、戻さない。
  #    総単位は値なので印を持てない。そのページの記録(contributed の total_credits)を外して、読み直しの対象から外す。
  #    直していないものには印を付けない。画面は全部を送ってくるので、値が変わったものだけを「直した」とする。
  #    並べ替えは、位置が変わったものを直したとする(並びを元に戻すのは、AI の読みで足された並びではなく人の並び)。
  # 2. 送られなかったものは消さない。置き換えるのは、送られた項目の値と並びだけ。消すのは、消すと明示されたものだけ
  #    (欠けた送信で規則が黙って落ちると、その要件が判定から消える)。
  # 3. 画面を開いてから読み取りなどで中身が変わっていたら、何も変えない(revision)。古い画面の値で、あとから
  #    読み取った規則を消してしまわないため。
  #
  # エラーが1つでもあれば、何も保存しない。
  class RequirementsEdit
    include Coercion
    include RuleEditing
    include DisplayEditing

    # edited は、直したものの数(画面の「保存しました」に出す)。
    Result = Struct.new(:errors, :edited, :notes, keyword_init: true) do
      def ok? = errors.empty?
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
    # エラーの文で欄を呼ぶ名前(画面の欄の名前と同じ)。
    FIELD_LABELS = { 'label' => '名前', 'name' => '名前', 'detail' => '注記', 'title' => '章の名前', 'subtitle' => '副題',
                     'required_credits' => '必要単位', 'required_label' => '必要単位が空のときの表示',
                     'expected_course_count' => '必修の科目数', 'categories' => '数える区分',
                     'required_categories' => '必修の区分', 'category' => '区分', 'group_by' => 'グループの分け方',
                     'reason' => '算入しない理由', 'check_id' => '確認する規則', 'check_ids' => '確認する規則',
                     'row_ids' => '数える行', 'credits_from_check' => '単位を確認する規則から取るか',
                     'counts_toward_total' => '卒業の総単位に数えるか' }.freeze
    KIND_NAMES = { 'rule' => '規則', 'group' => '章', 'row' => '行', 'subtotal' => '小計' }.freeze
    CONTRIBUTED_FIELD = { 'rule' => 'rules', 'group' => 'groups', 'subtotal' => 'subtotals' }.freeze

    def self.revision(document)
      document = {} unless document.is_a?(Hash)
      Digest::SHA256.hexdigest(JSON.generate(document.slice(*TRACKED)))
    end

    # 規則の型で、フォームの欄で直せる欄の { 欄 => 種類 }。画面とここで同じ表を使う。
    def self.rule_fields(rule)
      type = rule['type']
      adjustment = GraduationAssessment::Rules::ADJUSTMENTS.key?(type)
      fields = adjustment ? { 'detail' => :text } : RULE_COMMON_FIELDS.dup
      (Validation::Input::FIELD_KINDS[type] || {}).each do |field, kind|
        fields[field] = RULE_FIELD_KINDS.fetch(kind) if RULE_FIELD_KINDS.key?(kind)
      end
      fields
    end

    def initialize(curriculum, params)
      @curriculum = curriculum
      @params = params.to_h.with_indifferent_access
      @document = curriculum.document.deep_dup
      @pages = curriculum.pages.deep_dup
      @errors = []
      @edited = 0
      @notes = []
      @counted = []
    end

    # 行をロックした中で呼ぶこと(読み取りと同時に走っても、最新の document の上で直す)。
    def call
      return failure('この下書きの形が読めません(document がハッシュではありません)。') unless @document.is_a?(Hash)
      return failure(stale_message) if stale?

      apply_sections
      return failure(*@errors) if @errors.any?
      return Result.new(errors: [], edited: 0, notes: ['変えた箇所はありませんでした。']) if no_changes?

      @curriculum.update!(document: @document, pages: @pages)
      Result.new(errors: [], edited: @edited, notes: @notes)
    end

    private

    def failure(*messages) = Result.new(errors: messages, edited: 0, notes: [])

    def stale?
      @params[:revision].present? && @params[:revision] != self.class.revision(@document)
    end

    def stale_message
      'この画面を開いたあとに、要件表の中身が変わっています(読み取りや、ほかの操作)。何も保存していません。' \
        '画面を開き直して、もう一度直してください。'
    end

    def no_changes?
      @document == @curriculum.document && @pages == @curriculum.pages
    end

    def apply_sections
      edit_categories
      edit_rules
      add_new_rule
      edit_display
      decide_annotations
    end

    # ---- 区分 ----

    def edit_categories
      entries = entries(@params[:categories], 'categories') or return
      categories = list_of(@document, 'categories') or return

      entries.each do |entry|
        category = categories.find { |item| item['key'] == (entry[:key] || entry[:id]) }
        next error("区分「#{entry[:key]}」は下書きにありません。") unless category

        mark(category, assign(category, entry, CATEGORY_FIELDS, "区分「#{category['key']}」").any?)
      end
    end

    # ---- 注釈 ----

    def decide_annotations
      decisions = @params[:annotations]
      return if decisions.nil?
      return error('注釈の扱いの形が違います。') unless decisions.is_a?(Hash)

      decisions.each do |id, decision|
        next unless decision.is_a?(Hash) && decision[:disposition].present?

        category = decision[:category].to_s.presence
        problem = Annotations.decide(@document, @pages, id.to_s, decision[:disposition].to_s, category: category)
        problem ? error(problem) : @edited += 1
      end
    end

    # ---- 部品 ----

    def error(message)
      @errors << message
      nil
    end

    def list_of(owner, field)
      value = owner[field]
      return owner[field] = [] if value.nil?
      return value if value.is_a?(Array) && value.all?(Hash)

      error("#{field} が配列でないか、ハッシュでない要素があるため、この画面では直せません。")
    end

    # 送られた項目の配列。配列でも、{ '0' => {...}, '1' => {...} } でも受ける。無ければ nil。
    def entries(value, name)
      return if value.nil?
      return value if value.is_a?(Array) && value.all?(Hash)
      return value.values if value.is_a?(Hash) && value.values.all?(Hash)

      error("#{name} の形が違います。")
    end

    # 送られた値を項目に当てる。値が変わった欄の名前を返す(変わらなければ空)。
    # 画面は全部の欄を送ってくる。書式の違い(前後の空白・改行の形・無い欄と空の欄)だけの差は、直したことにしない。
    # 直したことにすると、触っていない項目まで確認済みの印が付き、読み直しで AI の読みを受け取れなくなる。
    def assign(item, entry, fields, name)
      fields.filter_map do |field, kind|
        next unless entry.key?(field)

        value = coerce(entry[field], kind, "#{name}の#{FIELD_LABELS.fetch(field, field)}")
        next if value == :invalid || same?(kind, field, value, item[field])

        item[field] = value
        field
      end
    end

    # 直した項目に印を付ける(直していなければ何もしない)。直した数は項目ごとに1つ数える。
    def mark(item, changed)
      return unless changed

      @edited += 1 unless @counted.include?(item.object_id)
      @counted << item.object_id
      item[DraftMerge::CONFIRMED] = true
    end

    def destroy?(entry)
      TRUE_VALUES.include?(entry[:_destroy])
    end

    # 消したものを記録する。読み直しが、同じ id を戻さないように。removed には消した id を積む。戻り値は nil。
    def discard(item, kind, removed = [], group_id = nil)
      removed << item['id']
      (@document[DraftMerge::REMOVED] ||= []) << { 'kind' => kind, 'id' => item['id'],
                                                   'page' => owner_page(kind, item['id'], group_id) }
      @edited += 1
      @notes << "#{KIND_NAMES.fetch(kind)}「#{item['id']}」を消しました。読み直しても戻りません。"
      nil
    end

    # 消したものを足したページ。読み直す前の警告で、どのページの読み直しで戻らないかを言うために持つ。
    def owner_page(kind, id, group_id)
      field = CONTRIBUTED_FIELD.fetch(kind, 'groups')
      target = group_id || id
      @pages.find { |page| Array(page.dig('contributed', field)).include?(target) }&.dig('page')
    end
  end
end

