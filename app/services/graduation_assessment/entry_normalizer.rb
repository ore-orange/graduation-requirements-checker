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

    def normalize(entries, course)
      unless course
        entries.each { |entry| unknown(entry) }
        return
      end

      values = entries.map { |entry| Ledger.decimal(entry[:credits]) }.uniq
      approvals = entries.pluck(:approved).uniq
      item = @ledger.add(course, values.one? ? values.first : nil)
      excluded = exclusion(course, approvals)
      return item.reason = excluded if excluded

      reason = record_review_reason(course, values, approvals)
      return @ledger.quarantine(item, reason) if reason

      item.counted = item.credits
      inspect_metadata(item)
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
      if Catalogue::CATEGORIES.exclude?(course['category'])
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

    def inspect_metadata(item)
      inspect_provider(item)
      inspect_language(item)
      inspect_nominal_credit(item)
    end

    def inspect_provider(item)
      course = item.course
      return unless course['category'] == 'fusion' && Catalogue::PROVIDERS.exclude?(course['provider'])

      @ledger.note(item, '工学融合の提供コースが未確認')
      @ledger.fusion_provider_unknown = true
    end

    def inspect_language(item)
      course = item.course
      return unless course['category'] == 'foreign_language' && course['language'].blank?

      @ledger.note(item, '外国語の言語が未確認（一外国語4単位の集計には未算入）')
      @ledger.foreign_language_unknown = true
    end

    def inspect_nominal_credit(item)
      course = item.course
      return unless @catalogue.specified?(course)
      return if item.credits == Ledger.decimal(course['credits'])

      @ledger.note(item, '指定科目の所定単位数と修得・予定単位数の対応が未確認')
      @ledger.uncertain_roles.concat(@catalogue.roles(course))
      @ledger.uncertain_required << course['key'] if course['required']
    end

    def unknown(entry)
      @ledger.external(entry, nil, '科目の正規キーを科目表と照合できないため、分類・同一性の確認が必要', review: true)
    end

    def normalize_unresolved(entry)
      course = @catalogue.find(entry[:key])
      excluded = @catalogue.exclusion(course) if course
      reason = excluded || entry[:reason] || '履修状態が未確認のため実績・見込みのいずれにも算入していません'
      @ledger.external(entry, course, reason, review: excluded.nil?)
    end
  end
end

