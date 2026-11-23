# frozen_string_literal: true

module CurriculumImport
  # 要件表の1ページの読み取り結果を、下書きの document に足す(取り除く)。
  #
  # ページごとに「このページが足したもの(contributed)」を返し、読み直すときはそれだけを外してから足し直す。
  # 別のページが先に足した区分・規則などと識別子が重なったときは、先のものを残し、警告(warnings)にする。
  # どちらが正しいかは機械では決めず、人が確認画面で直す。
  module RequirementsMerge
    LISTS = { 'categories' => 'key', 'roles' => 'key', 'rules' => 'id' }.freeze
    LIST_NAMES = { 'categories' => '区分', 'roles' => '役割', 'rules' => '規則' }.freeze

    module_function

    # [新しい document, contributed, warnings]
    def merge(document, answer)
      document = document.deep_dup
      document['format_version'] = 2
      contributed = {}
      warnings = []
      LISTS.each do |list, key|
        contributed[list] = add_entries(document, list, key, answer.fetch(list, []), warnings)
      end
      merge_display(document, answer['display'] || {}, contributed, warnings)
      [document, contributed, warnings]
    end

    # contributed に書かれたものだけを document から外す。
    def withdraw(document, contributed)
      document = document.deep_dup
      return document if contributed.blank?

      LISTS.each do |list, key|
        removed = Array(contributed[list])
        document[list] = Array(document[list]).reject { |entry| removed.include?(entry[key]) } if document.key?(list)
      end
      withdraw_display(document['display'], contributed) if document['display'].is_a?(Hash)
      document
    end

    def add_entries(document, list, key, entries, warnings)
      existing = Array(document[list])
      added = []
      entries.each do |entry|
        if existing.any? { |item| item[key] == entry[key] }
          warnings << "#{LIST_NAMES.fetch(list)} #{entry[key]} は別のページで読み取り済みのため、先のものを残しました"
        else
          existing << entry
          added << entry[key]
        end
      end
      document[list] = existing
      added
    end

    def merge_display(document, display, contributed, warnings)
      target = (document['display'] ||= { 'total_credits' => nil, 'groups' => [] })
      merge_total(target, display['total_credits'], contributed, warnings)
      contributed['groups'] = []
      contributed['rows'] = []
      Array(display['groups']).each { |group| merge_group(target, group, contributed) }
    end

    def merge_total(target, total, contributed, warnings)
      return if total.nil?

      if target['total_credits'].nil?
        target['total_credits'] = total
        contributed['total_credits'] = true
      elsif target['total_credits'] != total
        warnings << "卒業総単位が別のページの読み取り(#{target['total_credits']})と違うため、先のものを残しました(#{total})"
      end
    end

    # 同じ見出しが次のページに続いているときは、行だけを足す。
    def merge_group(target, group, contributed)
      existing = target['groups'].find { |item| item['id'] == group['id'] }
      unless existing
        target['groups'] << group
        contributed['groups'] << group['id']
        return
      end

      Array(group['rows']).each do |row|
        next if existing['rows'].any? { |item| item['id'] == row['id'] }

        existing['rows'] << row
        contributed['rows'] << [group['id'], row['id']]
      end
    end

    def withdraw_display(display, contributed)
      display['total_credits'] = nil if contributed['total_credits']
      groups = Array(contributed['groups'])
      display['groups'] = Array(display['groups']).reject { |group| groups.include?(group['id']) }
      Array(contributed['rows']).each do |group_id, row_id|
        group = display['groups'].find { |item| item['id'] == group_id }
        group['rows'] = group['rows'].reject { |row| row['id'] == row_id } if group
      end
    end
  end
end

