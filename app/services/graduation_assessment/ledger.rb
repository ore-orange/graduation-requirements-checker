# frozen_string_literal: true

class GraduationAssessment
  # 算入可能な単位と、未確定事項が影響する区分・科目を一緒に保持する。
  class Ledger
    Item = Struct.new(:course, :credits, :counted, :reason, keyword_init: true)
    attr_reader :items, :notes, :uncertain_roles, :uncertain_required
    attr_accessor :fusion_provider_unknown, :foreign_language_unknown, :unknown_identity

    def self.decimal(value)
      return unless value.is_a?(Numeric)

      number = BigDecimal(value.to_s)
      number if number.finite? && number >= Catalogue::ZERO
    rescue ArgumentError
      nil
    end

    def initialize(catalogue)
      @catalogue = catalogue
      @items = {}
      @notes = []
      @extra_results = []
      @uncertain_categories = []
      @uncertain_roles = []
      @uncertain_required = []
      @unknown_identity = false
    end

    def add(course, credits)
      item = Item.new(course: course, credits: credits, counted: Catalogue::ZERO, reason: '卒業単位に算入')
      items[course.fetch('key')] = item
      item
    end

    def note(item, reason)
      item.reason = reason
      notes << "#{item.course.fetch('name')}：#{reason}"
    end

    def mark_uncertain(course)
      @uncertain_categories << course['category']
      uncertain_roles.concat(@catalogue.roles(course))
      uncertain_required << course['key'] if course['required']
    end

    def quarantine(item, reason)
      item.counted = Catalogue::ZERO
      mark_uncertain(item.course)
      note(item, reason)
    end

    def external(entry, course, reason, review:)
      name = course ? course.fetch('name') : (entry[:name] || entry[:key] || '科目不明')
      if review
        notes << "#{name}：#{reason}"
        mark_external_uncertainty(course)
      end
      @extra_results << CourseResult.new(key: entry[:key], name: name, credits: self.class.decimal(entry[:credits]),
                                         counted_credits: Catalogue::ZERO, reason: reason)
    end

    def mark_external_uncertainty(course)
      return mark_uncertain(course) if course

      @unknown_identity = true
    end

    def uncertain?(categories)
      unknown_identity || @uncertain_categories.intersect?(categories)
    end

    def sum(categories)
      items.values.sum(Catalogue::ZERO) do |item|
        categories.include?(item.course['category']) ? item.counted : Catalogue::ZERO
      end
    end

    def total
      items.values.sum(Catalogue::ZERO, &:counted)
    end

    def acquired?(course)
      item = items[course['key']]
      item&.counted&.positive? && uncertain_required.exclude?(course['key']) &&
        !@catalogue.roles(course).intersect?(uncertain_roles)
    end

    def selected_role?(role)
      items.values.any? { |item| item.counted.positive? && @catalogue.roles(item.course).include?(role) }
    end

    def quarantine_roles(roles, reason)
      items.each_value do |item|
        quarantine(item, reason) if item.counted.positive? && @catalogue.roles(item.course).intersect?(roles)
      end
    end

    def apply_natural_cap
      remaining = BigDecimal('2')
      # 入力順ではなく正規キー順に上限を配分し、説明を安定させる。
      items.sort_by { |key, _| key }.each do |_, item|
        next unless item.course['category'] == 'natural' && item.counted.positive?

        allowed = [remaining, item.counted].min
        item.reason = "自然系は卒業算入上限2単位（この科目は#{allowed.to_s('F')}単位を算入）" if allowed < item.counted
        item.counted = allowed
        remaining -= allowed
      end
    end

    def grouped_credits(category, field)
      items.values.each_with_object(Hash.new(Catalogue::ZERO)) do |item, totals|
        next unless item.course['category'] == category

        group = item.course[field]
        totals[group] += item.counted if group.present?
      end
    end

    def course_results
      results = items.map do |key, item|
        CourseResult.new(key: key, name: item.course.fetch('name'), credits: item.credits,
                         counted_credits: item.counted, reason: item.reason)
      end
      (results + @extra_results).freeze
    end
  end
end

