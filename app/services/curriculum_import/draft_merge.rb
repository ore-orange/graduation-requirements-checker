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

    # そのページが前に足したもの(contributed)を、document から外す。ページの種別を替えたときにも使う。
    # いまの種別ではなく、記録に何があるかで外す。種別を替えて読み直しても、前の種別の分を取り残さない。
    # 確認済みの科目だけは人が見たものなので外さない。戻り値は、残した確認済みの科目の key。
    #
    # 暫定: 規則・表示は、人が直した分も外す。科目が確認済みを守るのと非対称で、いまは人が規則・表示を直す画面が無いので
    # 失うものは無い。Task 19 で直せるようにするとき、次を一緒に入れること。
    #  - 直した規則・章・行に confirmed を付け、ここでも「&& !rule[CONFIRMED]」の守りを足す(courses と同じ)
    #  - add_rules は、残した(直した)規則が持つ id を取られたものとして扱う
    #  - 「読み直す」を押す前に、直した分が消えることを警告する
    def self.withdraw(document, contributed, page)
      contributed ||= {}
      withdraw_requirements(document, contributed)
      ApprovalNotes.replace_page_notes(document, page, [])
      keys = Array(contributed['courses'])
      document['courses']&.reject! { |course| keys.include?(course['key']) && !course[CONFIRMED] }
      Array(document['courses']).select { |course| keys.include?(course['key']) }.pluck('key')
    end

    def self.withdraw_requirements(document, contributed)
      display = document['display'] || {}
      drop(document['rules'], contributed['rules'])
      drop(display['groups'], contributed['groups'])
      drop(display['subtotals'], contributed['subtotals'])
      display.delete('total_credits') if contributed['total_credits']
    end

    def self.drop(list, ids)
      list&.reject! { |item| Array(ids).include?(item['id']) }
    end
    private_class_method :withdraw_requirements, :drop

    # 要件表のページ。区分・役割はキーで足し合わせ(先にあるものを優先)、規則と表示はそのページの分を入れ直す。
    # 戻り値は、このページが足したものの記録(次に読み直すときに外す)。
    def requirements(answer)
      answer = answer.deep_dup
      # 科目表として読んだページを要件表に替えたとき、残した確認済みの科目の key も記録に引き継ぐ(取り残さない)。
      kept = withdraw_previous
      add_keyed(@document['categories'], answer['categories'], '区分')
      add_roles(answer['roles'])
      rule_ids = add_rules(Array(answer['rules']))
      display = add_display(answer['display'] || {}, rule_ids)
      touch_source
      { 'rules' => rule_ids.values, 'groups' => display[:groups], 'subtotals' => display[:subtotals],
        'total_credits' => display[:total_credits] }.tap { |record| record['courses'] = kept if kept.any? }
    end

    # 科目表のページ。番号が別のページの科目と同じ行は上書きせず別の key で残す(重複の判断は、あとの突き合わせと人がする)。
    def courses(answer)
      courses = @document['courses']
      kept_keys = withdraw_previous
      known = courses.select { |course| kept_keys.include?(course['key']) }.map { |course| identity(course) }
      added = answer['courses'].each_with_index.filter_map do |row, index|
        next if known.include?(identity(row))

        course_entry(row, index, courses).tap { |entry| courses << entry }
      end
      touch_source
      { 'courses' => kept_keys + added.pluck('key') }
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

    # key で足す。先にあるもの(別のページが足した・人が直した)を優先し、同じ key の読み取りでは上書きしない。
    # 同じ key で名前が違えば、先を残して警告に出す(総単位の食い違いと同じ扱い)。
    def add_keyed(target, incoming, noun)
      incoming.to_a.each do |entry|
        existing = target.find { |other| other['key'] == entry['key'] }
        if existing.nil?
          target << entry
        else
          @warnings.concat(keyed_differences(noun, existing, entry))
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
                       "(先: #{existing['counts_toward_total']}、このページ: #{entry['counts_toward_total']})。"
      end
      differences
    end

    # roles は任意の欄。読み取りが返したときだけ作る(欄が無ければ、規則の paths から役割のキーを導く)。
    def add_roles(incoming)
      return if incoming.blank?

      add_keyed(@document['roles'] ||= [], incoming, '役割')
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
    def add_all(items, taken)
      Array(items).map do |item|
        yield(item, taken).tap { |added| taken << added['id'] }
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

    def add_group(group, rule_ids, row_ids, taken, row_taken)
      group = group.merge('id' => unique_id(group['id'], taken))
      group['check_id'] = rule_ids.fetch(group['check_id'], group['check_id']) if group['check_id']
      group['rows'] = Array(group['rows']).map { |row| add_row(row, rule_ids, row_ids, row_taken) }
      group
    end

    # taken には、既にある行と、このページで付けた行の id をすべて積む(同じ id が3つ以上あっても重ならない)。
    def add_row(row, rule_ids, row_ids, taken)
      id = unique_id(row['id'], taken)
      taken << id
      row_ids[row['id']] ||= id
      row.merge('id' => id, 'check_ids' => remap(row['check_ids'], rule_ids))
    end

    def add_subtotal(subtotal, rule_ids, row_ids, taken)
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

