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
    CONFIRMED = 'confirmed'
    # 確認画面で人が消した規則・章・行・小計の記録。読み直しが、消したものを黙って戻さないための印。
    # { 'kind' => 'rule' | 'group' | 'row' | 'subtotal', 'id' => 消した id, 'page' => それを足したページ(分からなければ nil) }
    REMOVED = 'removed_by_human'

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
      record = { 'rules' => kept_ids('rules') + added_rules, 'groups' => kept_ids('groups') + display[:groups],
                 'subtotals' => kept_ids('subtotals') + display[:subtotals],
                 'total_credits' => display[:total_credits] }
      record['courses'] = @kept['courses'] if @kept['courses']
      record
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

    # 人が消したもの。読み直しで同じ id が戻ってきても、入れない(人の訂正を黙って取り消さない)。
    def removed?(kind, id)
      Array(@document[REMOVED]).any? { |entry| entry['kind'] == kind && entry['id'] == id }
    end

    # key で足す。先にあるもの(別のページが足した・人が直した)を優先し、同じ key の読み取りでは上書きしない。
    # 同じ key で名前が違えば、先を残して警告に出す(総単位の食い違いと同じ扱い)。
    def add_keyed(target, incoming, noun)
      incoming.to_a.each do |entry|
        existing = target.find { |other| other['key'] == entry['key'] }
        if existing.nil?
          target << entry
        elsif existing[CONFIRMED]
          # 人が直した区分は、読み直した内容で変えない。数えるかどうかの「数えない側に倒す」もしない(人が数えると決めた)。
          @warnings.concat(Differences.kept_category(noun, existing, entry))
        else
          @warnings.concat(keyed_differences(noun, existing, entry))
          # 総単位に数えるかが食い違うときは、数えない側に倒す。数える側に倒すと単位の水増しになり、数えない側は要確認になる。
          existing['counts_toward_total'] = false if entry['counts_toward_total'] == false
        end
      end
    end

    # 名前と、総単位に数えるかどうか(区分だけの欄。単位が総単位に入るかを決める)の食い違い。
    def keyed_differences(noun, existing, entry)
      differences = []
      if existing['label'] != entry['label']
        differences << "#{noun} #{entry['key']} の名前が別のページと食い違います(先: #{existing['label']}、このページ: #{entry['label']})。"
      end
      if existing['counts_toward_total'] != entry['counts_toward_total']
        differences << "#{noun} #{entry['key']} の「卒業の総単位に数えるか」が別のページと食い違います" \
                       "(先: #{existing['counts_toward_total']}、このページ: #{entry['counts_toward_total']})。" \
                       '数えない(false)側に合わせました。確かめてください。'
      end
      differences
    end

    # roles は任意の欄。読み取りが返したときだけ作る(欄が無ければ、規則の paths から役割のキーを導く)。
    def add_roles(incoming)
      return if incoming.blank?

      add_keyed(@document['roles'] ||= [], incoming, '役割')
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
      added = rules.filter_map do |rule|
        kept = kept_ids('rules').include?(rule['id'])
        id = kept ? rule['id'] : unique_id(rule['id'], taken)
        mapping[rule['id']] ||= id
        next note_kept('規則', @document['rules'], rule) if kept
        next if removed?('rule', id)

        taken << id
        @document['rules'] << rule.merge('id' => id, 'source_page' => @label)
        id
      end
      [mapping, added]
    end

    # 残した(人が直した)ものと、読み直した結果が違えば、警告に残す。戻り値は nil(足したものに数えない)。
    def note_kept(noun, list, incoming)
      kept = list.find { |item| item['id'] == incoming['id'] }
      differences = kept ? Differences.between(kept, incoming) : []
      @warnings << Differences.sentence(noun, incoming['id'], differences) if differences.any?
      nil
    end

    def add_display(display, rule_ids)
      target = @document['display']
      total = !adopt_total_credits(display['total_credits']).nil?
      row_ids = {}
      row_taken = target['groups'].flat_map { |group| group['rows'].pluck('id') }
      groups = add_all(display['groups'], target['groups'].pluck('id')) do |group, taken|
        add_group(group, rule_ids, row_ids, taken, row_taken)
      end
      subtotals = add_all(display['subtotals'], Array(target['subtotals']).pluck('id')) do |subtotal, taken|
        add_subtotal(subtotal, rule_ids, row_ids, taken)
      end
      target['groups'].concat(groups)
      (target['subtotals'] ||= []).concat(subtotals) if subtotals.any?
      { groups: groups.pluck('id'), subtotals: subtotals.pluck('id'), total_credits: total }
    end

    # このページの中で同じ id が2つあっても付け替えられるよう、付けた id を taken に積みながら足す。
    # ブロックが nil を返したもの(人が直して残した・人が消した)は足さない。
    def add_all(items, taken)
      Array(items).filter_map do |item|
        yield(item, taken)&.tap { |added| taken << added['id'] }
      end
    end

    # 総単位は、先に別のページで読めた値を優先する。食い違うときは捨てずに警告に残す。
    # このページの値を採ったときだけ、その値を返す(読み直しのときに外す印になる)。
    def adopt_total_credits(incoming)
      return if incoming.nil?

      display = @document['display']
      return display['total_credits'] = incoming if display['total_credits'].nil?

      current = display['total_credits']
      @warnings << "卒業に必要な総単位が別のページの値(#{current})と食い違います(このページ: #{incoming})。" if current != incoming
      nil
    end

    # 人が直して残した章は、行ごと入れない(直した行は、その章の中にある)。
    def add_group(group, rule_ids, row_ids, taken, row_taken)
      return note_kept('章', @document['display']['groups'], group) if kept_ids('groups').include?(group['id'])

      group = group.merge('id' => unique_id(group['id'], taken))
      return if removed?('group', group['id'])

      group['check_id'] = rule_ids.fetch(group['check_id'], group['check_id']) if group['check_id']
      group['rows'] = Array(group['rows']).filter_map { |row| add_row(row, rule_ids, row_ids, row_taken) }
      group
    end

    # taken には、既にある行と、このページで付けた行の id をすべて積む(同じ id が3つ以上あっても重ならない)。
    # 人が消した行は戻さない。
    def add_row(row, rule_ids, row_ids, taken)
      id = unique_id(row['id'], taken)
      taken << id
      row_ids[row['id']] ||= id
      return if removed?('row', id)

      row.merge('id' => id, 'check_ids' => remap(row['check_ids'], rule_ids))
    end

    def add_subtotal(subtotal, rule_ids, row_ids, taken)
      if kept_ids('subtotals').include?(subtotal['id'])
        return note_kept('小計', @document['display']['subtotals'], subtotal)
      end

      id = unique_id(subtotal['id'], taken)
      return if removed?('subtotal', id)

      subtotal.merge('id' => id, 'row_ids' => remap(subtotal['row_ids'], row_ids),
                     'check_ids' => remap(subtotal['check_ids'], rule_ids))
    end

    # このページが定義した id だけを付け替える。別のページの規則を指す参照は、そのまま残す。
    def remap(references, mapping)
      Array(references).map { |reference| mapping.fetch(reference, reference) }
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

