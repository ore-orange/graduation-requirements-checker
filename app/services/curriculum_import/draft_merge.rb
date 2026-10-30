# frozen_string_literal: true

module CurriculumImport
  # 1ページ分の読み取りの結果を、下書きの document に統合する。
  #
  # 読み取りは1ページずつで、答えは「そのページに書かれていた分」の断片にすぎない。
  # 便覧の文書(Catalogue が読む形)に要る欄のうち、ページから読めないもの(key・source・source_page・selectable・sources)と、
  # ページを跨ぐと衝突するもの(規則・表示の id、科目の key)は、ここが決める。
  #
  # 同じページを読み直すと、そのページが前回足した分(previous = ページの contributed)を外してから入れ直す。
  # 二重にならず、別のページが足した分には触れない。確認済みの科目と、人が直した規則・章・行・小計・区分は、
  # 人が見たものなので外さず、読み直した側の値で上書きもしない(Withdrawal)。
  class DraftMerge
    include KeyedMerge
    include DisplayMerge

    CONFIRMED = 'confirmed'
    # 確認画面で人が消した規則・章・行・小計の記録。読み直しが、消したものを黙って戻さないための印。
    # { 'kind' => 'rule' | 'group' | 'row' | 'subtotal', 'id' => 消した id, 'page' => それを足したページ(分からなければ nil) }
    REMOVED = 'removed_by_human'
    # ページの記録(contributed)の total_credits が、人が直した値を指すときの印。true(このページの値を採った)ではないので、
    # 読み直しは外さない。false(採らなかった)とも区別し、読み直した値と違うときに「人が直した値を残した」と言える。
    HUMAN = 'human'

    # 規則・科目に付ける出典。便覧の PDF ページ番号で、規則の「出典」欄にそのまま出る。
    def self.source_page_label(page)
      "PDF#{page}ページ"
    end

    attr_reader :warnings

    def initialize(document, curriculum:, page:, previous: nil)
      @document = document
      @curriculum = curriculum
      @page = page
      @label = self.class.source_page_label(page)
      @previous = previous || {}
      @warnings = []
      @kept = {}
      @origins = Origins.new(@previous['origins'], page)
      ensure_skeleton
    end

    # そのページが前に足したもの(contributed)を、document から外す。ページの種別を替えたときにも使う。
    # 人が見て直したもの(confirmed)は外さない。戻り値は、残したものの記録(Withdrawal.call)。
    def self.withdraw(document, contributed, page)
      Withdrawal.call(document, contributed, page)
    end

    # 要件表のページ。区分・役割はキーで足し合わせ(先にあるものを優先)、規則と表示はそのページの分を入れ直す。
    # 人が直した規則・章・行・小計は、入れ直さずに残す(withdraw)。読み直した側の内容は採らず、違うときは警告に残す。
    # 戻り値は、このページが足したものの記録(次に読み直すときに外す)。残したものも、このページのものとして記録する。
    def requirements(answer)
      answer = answer.deep_dup
      # 科目表として読んだページを要件表に替えたとき、残した確認済みの科目の key も記録に引き継ぐ(取り残さない)。
      @kept = withdraw_previous
      add_keyed(@document['categories'], answer['categories'], '区分')
      add_roles(answer['roles'])
      rule_ids, added_rules = add_rules(Array(answer['rules']))
      display = add_display(answer['display'] || {}, rule_ids)
      touch_source
      contribution(added_rules, display)
    end

    # 科目表のページ。番号が別のページの科目と同じ行は上書きせず別の key で残す(重複の判断は、あとの突き合わせと人がする)。
    def courses(answer)
      courses = @document['courses']
      @kept = withdraw_previous
      kept_keys = kept_ids('courses')
      known = courses.select { |course| kept_keys.include?(course['key']) }.map { |course| identity(course) }
      added = answer['courses'].each_with_index.filter_map do |row, index|
        next if known.include?(identity(row))

        course_entry(row, index, courses).tap { |entry| courses << entry }
      end
      touch_source
      @kept.except('courses').merge('courses' => kept_keys + added.pluck('key'))
    end

    private

    # このページが足したものの記録。残したもの(人が直した)も、このページのものとして記録する。
    def contribution(added_rules, display)
      record = { 'rules' => kept_ids('rules') + added_rules, 'groups' => kept_ids('groups') + display[:groups],
                 'subtotals' => kept_ids('subtotals') + display[:subtotals],
                 'total_credits' => display[:total_credits] || human_total || false }
      origins = @origins.record(@kept['origins'])
      record['courses'] = @kept['courses'] if @kept['courses']
      record['origins'] = origins if origins.any?
      record
    end

    # 下書きの document は空から始まる。Catalogue が読める最低限の欄を、無ければ作る。
    def ensure_skeleton
      @document.reverse_merge!('format_version' => 2, 'department' => @curriculum.slug,
                               'admission_year' => @curriculum.admission_year,
                               'title' => @curriculum.title.presence || default_title)
      %w[sources categories rules courses].each { |field| @document[field] ||= [] }
      @document['display'] ||= {}
      @document['display']['groups'] ||= []
      ensure_source
    end

    def default_title
      "#{@curriculum.admission_year}年度入学 #{@curriculum.faculty_name} #{@curriculum.department_name}".strip
    end

    def source_id
      "handbook_#{@curriculum.admission_year}"
    end

    def ensure_source
      return if @document['sources'].any? { |source| source['id'] == source_id }

      @document['sources'] << { 'id' => source_id, 'title' => "#{default_title} 学生便覧(取り込み)" }
    end

    # 読み取り済みのページ(このページを含む)を、出典の「対象ページ」に出す。
    def touch_source
      numbers = (@curriculum.pages.select { |page| page['status'] == 'read' }.pluck('page') | [@page]).sort
      source = @document['sources'].find { |entry| entry['id'] == source_id }
      source['pages'] = "PDF#{numbers.join('・')}ページ"
    end

    def withdraw_previous
      self.class.withdraw(@document, @previous, @page)
    end

    def kept_ids(field)
      Array(@kept[field])
    end

    # 人が消したもの。読み直しで同じものが戻ってきても、入れない(人の訂正を黙って取り消さない)。
    # id が付け替わっていても同じものと分かるよう、消した時に持った由来(origin)でも照らす。
    def removed?(kind, id, origin)
      Array(@document[REMOVED]).any? do |entry|
        next false unless entry['kind'] == kind
        next false if entry['page'] && entry['page'] != @page

        entry['id'] == id || (entry['origin'].present? && entry['origin'] == origin)
      end
    end

    def human_total
      HUMAN if @previous['total_credits'] == HUMAN
    end

    # 規則を足す。別のページ・同じページの規則と id がぶつかるものは付け替える。
    # 戻り値は [{読んだ id => 実際の id(参照の付け替えに使う。同じ id が複数なら最初のもの)}, 足した規則の実際の id すべて]。
    # 読み直しで外すのは後者。前者だけを記録すると、付け替えた重複が外れず、読み直すたびに積もる。
    #
    # 人が直して残した規則(withdraw が残したもの)と同じ id の規則は、入れない。入れると、同じ id が2つになって
    # 付け替えが起き、直した規則と AI の読みが並ぶ(画面の行は先の1つを引くので、どちらが効くか分からなくなる)。
    # 人が消した規則は戻さない。どちらも、行などからの参照は同じ id のまま。消えた規則を指す行は、突き合わせが止める。
    def add_rules(rules)
      taken = @document['rules'].pluck('id')
      mapping = {}
      plan = @origins.match('rules', rules.pluck('id'), kept_ids('rules'))
      added = rules.zip(plan).filter_map do |rule, (origin, kept)|
        id = kept || unique_id(rule['id'], taken)
        mapping[rule['id']] ||= id
        next note_kept('規則', @document['rules'], id, rule) if kept
        next if removed?('rule', id, origin)

        taken << id
        @origins.remember('rules', id, origin)
        @document['rules'] << rule.merge('id' => id, 'source_page' => @label)
        id
      end
      [mapping, added]
    end

    # 残した(人が直した)ものと、読み直した結果が違えば、警告に残す。戻り値は nil(足したものに数えない)。
    # list の中では、前に付けた id(stored_id)で引く。読んだ id は付け替わっていることがある。
    def note_kept(noun, list, stored_id, incoming)
      kept = list.find { |item| item['id'] == stored_id }
      differences = kept ? Differences.between(kept, incoming) : []
      @warnings << Differences.sentence(noun, stored_id, differences) if differences.any?
      nil
    end

    # 総単位は、先に別のページで読めた値を優先する。食い違うときは捨てずに警告に残す。
    # このページの値を採ったときだけ、その値を返す(読み直しのときに外す印になる)。
    def adopt_total_credits(incoming)
      return if incoming.nil?

      display = @document['display']
      return display['total_credits'] = incoming if display['total_credits'].nil?

      current = display['total_credits']
      @warnings << Differences.total_credits(current, incoming, human: human_total.present?) if current != incoming
      nil
    end

    def unique_id(id, taken)
      return id unless taken.include?(id)

      candidate = "#{id}_p#{@page}"
      suffix = 1
      candidate = "#{id}_p#{@page}_#{suffix += 1}" while taken.include?(candidate)
      candidate
    end

    # 同じ科目かどうか。番号があれば番号、無ければ科目名(分類表にしか載っていない科目)。
    def identity(course)
      course['number'].presence || "name:#{course['name']}"
    end

    def course_entry(row, index, existing)
      number = row['number'].presence&.strip
      { 'key' => course_key(number, index, existing), 'number' => number, 'name' => row['name'],
        'credits' => row['credits'], 'category' => row['category'], 'required' => row['required'],
        'language' => row['language'], 'roles' => Array(row['roles']), 'source' => source_id,
        'source_page' => @label, 'review_reason' => row['review_reason'],
        'requires_approval' => row['requires_approval'] == true, 'selectable' => true }
    end

    # key は科目の同一性そのもの。別のページに同じ番号の行があっても潰れないよう、ぶつかったらページ番号を付ける。
    def course_key(number, index, existing)
      base = number ? "course_#{number}" : "p#{@page}_row#{index + 1}"
      unique_id(base, existing.pluck('key'))
    end
  end
end

