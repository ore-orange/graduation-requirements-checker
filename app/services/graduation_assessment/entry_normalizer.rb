# frozen_string_literal: true

class GraduationAssessment
  class EntryNormalizer
    def initialize(catalogue, ledger)
      @catalogue = catalogue
      @ledger = ledger
    end

    def call(completed, future, unresolved)
      earned = completed.group_by { |entry| entry[:key] }
      pending = future.group_by { |entry| entry[:key] }
      (earned.keys | pending.keys).each do |key|
        # 再履修予定で実際の修得単位を名目単位へ置き換えない。
        normalize(earned.key?(key) ? earned.fetch(key) : pending.fetch(key), @catalogue.find(key))
      end
      unresolved.each { |entry| normalize_unresolved(entry) }
    end

    private

    # 同じ科目の記録をまとめて1件として台帳に載せる。科目表に当たらなかった科目は、番号パターンで区分を
    # 推定できればその区分として数え、できなければ今までどおり要確認にする(安全側)。
    def normalize(entries, course)
      course ||= pattern_course(entries)
      return entries.each { |entry| unknown(entry) } unless course

      record(entries, course)
    end

    def record(entries, course)
      values = entries.map { |entry| Ledger.decimal(entry[:credits]) }.uniq
      approvals = entries.pluck(:approved).uniq
      item = @ledger.add(course, values.one? ? values.first : nil)
      excluded = exclusion(course, approvals)
      return item.reason = excluded if excluded

      reason = record_review_reason(course, values, approvals)
      return @ledger.quarantine(item, reason) if reason

      item.counted = item.credits
      inspect_nominal_credit(item)
    end

    def exclusion(course, approvals)
      @catalogue.exclusion(course) ||
        ('指導教員の承認がないため算入対象外' if course['requires_approval'] && approvals == [false])
    end

    def record_review_reason(course, values, approvals)
      if values.size > 1 || (course['requires_approval'] && approvals.size > 1)
        return '同一科目の複数記録で単位数または承認が一致せず、再履修・読み替えの確認が必要'
      end

      metadata_review_reason(course) || approval_or_credit_reason(course, values.first, approvals)
    end

    def metadata_review_reason(course)
      if @catalogue.category_keys.exclude?(course['category'])
        @ledger.unknown_identity = true
        return '科目の卒業要件上の分類が未確認'
      end
      return course['review_reason'] if course['review_reason'].present?
      return unless course['source'].blank? || course['source_page'].blank?

      '分類・算入を確認する一次資料の参照先が未確認'
    end

    def approval_or_credit_reason(course, credits, approvals)
      return '指導教員の承認状況が未確認' if course['requires_approval'] && approvals != [true]
      return unless credits.nil? || credits.zero?

      '修得・予定単位数が未確定または有効な正の数でない'
    end

    def inspect_nominal_credit(item)
      course = item.course
      return unless @catalogue.specified?(course)
      return if item.credits == Ledger.decimal(course['credits'])

      @ledger.note(item, '指定科目の所定単位数と修得・予定単位数の対応が未確認')
      @ledger.uncertain_roles.concat(@catalogue.roles(course))
      @ledger.uncertain_required << course['key'] if course['required']
    end

    # 科目表にも番号パターンにも当たらなかった科目。科目番号で名指しした除外に当たれば「算入対象外」と出し、
    # 当たらなければ今までどおり要確認にする(設計書 項目9)。どちらでも算入は0なので、単位は動かない。
    def unknown(entry)
      excluded = @catalogue.exclusion_by_number(entry[:number])
      reason = excluded || '科目の正規キーを科目表と照合できないため、分類・同一性の確認が必要'
      @ledger.external(entry, nil, reason, review: excluded.nil?)
    end

    # 科目表に無い科目の番号から、number_patterns を使って区分を推定する。
    # 成功すれば「科目表には未掲載」の合成科目を返す。失敗すれば nil。
    # 成功した科目は required / roles / requires_approval を持たない
    # (共通教育の個々の必修科目はこれとは別に科目表に残す)。
    #
    # 見るのは key ではなく number。科目表に当たらなかった履修の key は StudentWorkspace#catalogue_entries が
    # "unmatched:1" に振り替えるので、key には科目番号が残っていない。番号を持たない履修(科目番号の無い Course)は
    # 推定しない。安全側の設計: 推定できなければ今までどおり「要確認」のままになる。
    def pattern_course(entries)
      number = entries.first[:number]
      return nil if number.blank?

      category = @catalogue.pattern_category_for(number)
      return nil unless category

      { 'key' => number, 'number' => number, 'name' => entries.first[:name].to_s,
        'category' => category, 'source' => '科目番号のパターンから推定',
        'source_page' => '科目番号のパターンから推定（科目表には未掲載）' }
    end

    def normalize_unresolved(entry)
      course = @catalogue.find(entry[:key])
      excluded = course ? @catalogue.exclusion(course) : @catalogue.exclusion_by_number(entry[:number])
      reason = excluded || entry[:reason] || '履修状態が未確認のため実績・見込みのいずれにも算入していません'
      @ledger.external(entry, course, reason, review: excluded.nil?)
    end
  end
end

