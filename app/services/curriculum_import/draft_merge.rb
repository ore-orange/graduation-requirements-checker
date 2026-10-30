# frozen_string_literal: true

module CurriculumImport
  # 1ページ分の読み取りの結果を、下書きの document に統合する。
  #
  # 読み取りは1ページずつで、答えは「そのページに書かれていた分」の断片にすぎない。
  # 便覧の文書(Catalogue が読む形)に要る欄のうち、ページから読めないもの(key・source・source_page・selectable・sources)と、
  # ページを跨ぐと衝突するもの(規則・表示の id、科目の key)は、ここが決める。
  #
  # 同じページを読み直すと、そのページが前回足した分(previous = ページの contributed)を外してから入れ直す。
  # 二重にならず、別のページが足した分には触れない。確認済みの科目だけは、人が見たものなので外さない。
  class DraftMerge
    CONFIRMED = 'confirmed'

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
      ensure_skeleton
    end

    # 要件表のページ。区分・役割はキーで足し合わせ(先にあるものを優先)、規則と表示はそのページの分を入れ直す。
    # 戻り値は、このページが足したものの記録(次に読み直すときに外す)。
    def requirements(answer)
      answer = answer.deep_dup
      forget_requirements
      add_keyed(@document['categories'], answer['categories'])
      add_roles(answer['roles'])
      rule_ids = add_rules(Array(answer['rules']))
      display = add_display(answer['display'] || {}, rule_ids)
      touch_source
      { 'rules' => rule_ids.values, 'groups' => display[:groups], 'subtotals' => display[:subtotals],
        'total_credits' => display[:total_credits] }
    end

    # 科目表のページ。番号が別のページの科目と同じ行は上書きせず別の key で残す(重複の判断は、あとの突き合わせと人がする)。
    def courses(answer)
      previous_keys = Array(@previous['courses'])
      courses = @document['courses']
      courses.reject! { |course| previous_keys.include?(course['key']) && !course[CONFIRMED] }
      kept = courses.select { |course| previous_keys.include?(course['key']) }
      known = kept.map { |course| identity(course) }
      added = answer['courses'].each_with_index.filter_map do |row, index|
        next if known.include?(identity(row))

        course_entry(row, index, courses).tap { |entry| courses << entry }
      end
      touch_source
      { 'courses' => (kept + added).pluck('key') }
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

    def forget_requirements
      @document['rules'].reject! { |rule| Array(@previous['rules']).include?(rule['id']) }
      display = @document['display']
      display['groups'].reject! { |group| Array(@previous['groups']).include?(group['id']) }
      display['subtotals']&.reject! { |subtotal| Array(@previous['subtotals']).include?(subtotal['id']) }
      display.delete('total_credits') if @previous['total_credits']
    end

    # key で足す。先にあるもの(別のページが足した・人が直した)を優先し、同じ key の読み取りでは上書きしない。
    def add_keyed(target, incoming)
      incoming.to_a.each do |entry|
        target << entry if target.none? { |existing| existing['key'] == entry['key'] }
      end
    end

    # roles は任意の欄。読み取りが返したときだけ作る(欄が無ければ、規則の paths から役割のキーを導く)。
    def add_roles(incoming)
      return if incoming.blank?

      add_keyed(@document['roles'] ||= [], incoming)
    end

    # 規則を足す。別のページの規則と id がぶつかるものは付け替え、{読んだ id => 実際の id} を返す。
    def add_rules(rules)
      taken = @document['rules'].pluck('id')
      rules.each_with_object({}) do |rule, ids|
        id = unique_id(rule['id'], taken)
        ids[rule['id']] ||= id
        taken << id
        @document['rules'] << rule.merge('id' => id, 'source_page' => @label)
      end
    end

    def add_display(display, rule_ids)
      target = @document['display']
      total = !adopt_total_credits(display['total_credits']).nil?
      row_ids = {}
      groups = Array(display['groups']).map { |group| add_group(group, rule_ids, row_ids) }
      subtotals = Array(display['subtotals']).map { |subtotal| add_subtotal(subtotal, rule_ids, row_ids) }
      target['groups'].concat(groups)
      (target['subtotals'] ||= []).concat(subtotals) if subtotals.any?
      { groups: groups.pluck('id'), subtotals: subtotals.pluck('id'), total_credits: total }
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

    def add_group(group, rule_ids, row_ids)
      taken_groups = @document['display']['groups'].pluck('id')
      group = group.merge('id' => unique_id(group['id'], taken_groups))
      group['check_id'] = rule_ids.fetch(group['check_id'], group['check_id']) if group['check_id']
      group['rows'] = Array(group['rows']).map { |row| add_row(row, rule_ids, row_ids) }
      group
    end

    def add_row(row, rule_ids, row_ids)
      taken = @document['display']['groups'].flat_map { |group| group['rows'].pluck('id') } + row_ids.values
      id = unique_id(row['id'], taken)
      row_ids[row['id']] ||= id
      row.merge('id' => id, 'check_ids' => remap(row['check_ids'], rule_ids))
    end

    def add_subtotal(subtotal, rule_ids, row_ids)
      taken = Array(@document['display']['subtotals']).pluck('id')
      subtotal.merge('id' => unique_id(subtotal['id'], taken), 'row_ids' => remap(subtotal['row_ids'], row_ids),
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

