# frozen_string_literal: true

class GraduationAssessment
  class CreditCheck
    def initialize(ledger)
      @ledger = ledger
    end

    def call(id, label, categories, required, **options)
      counted = options.fetch(:counted) { @ledger.sum(categories) }
      review = options[:review] || @ledger.uncertain?(categories)
      status = self.class.status(counted >= required, review)
      Check.new(id: id, label: label, status: status, counted_credits: counted,
                required_credits: required, missing_courses: [], source: options.fetch(:source, Catalogue::SOURCE),
                detail: detail(counted, required, status, options[:detail]))
    end

    def self.status(satisfied, review)
      return :satisfied if satisfied

      review ? :needs_review : :unmet
    end

    private

    def detail(counted, required, status, explanation)
      text = "#{explanation} 確認済み算入#{counted.to_s('F')}／必要#{required}単位。"
      deficit = [BigDecimal(required.to_s) - counted, Catalogue::ZERO].max
      text += "不足#{deficit.to_s('F')}単位。" if status == :unmet
      text += '未確認事項により不足の確定はできません。' if status == :needs_review
      text.strip
    end
  end
end

