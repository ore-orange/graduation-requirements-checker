# frozen_string_literal: true

class GraduationAssessment
  class Evaluation
    def initialize(catalogue)
      @catalogue = catalogue
      @ledger = Ledger.new(catalogue)
    end

    def call(completed, future, unresolved)
      EntryNormalizer.new(@catalogue, @ledger).call(completed, future, unresolved)
      alternatives = BasicAlternatives.new(@catalogue, @ledger).call
      @ledger.apply_natural_cap
      checks = CommonChecks.new(@catalogue, @ledger).call + basic_checks(alternatives) +
               SpecialistChecks.new(@catalogue, @ledger).call + [total_check]
      Snapshot.new(status: status(checks), counted_credits: @ledger.total, checks: checks.freeze,
                   review_notes: @ledger.notes.uniq.freeze, course_results: @ledger.course_results)
    end

    private

    def basic_checks(alternatives)
      requirements = @catalogue.requirements
      role = RoleCheck.new(@catalogue, @ledger)
      [
        CreditCheck.new(@ledger).call('basic_total', '専門基礎教育の合計', ['basic'], 6),
        role.call('calculus', '微分積分学の指定系列', requirements.fetch('calculus_paths'),
                  review: alternatives.calculus_ambiguous),
        role.call('physics', '物理学の指定科目', requirements.fetch('physics_roles').zip,
                  review: alternatives.physics_ambiguous)
      ]
    end

    def total_check
      CreditCheck.new(@ledger).call('total', '卒業算入総単位', Catalogue::CATEGORIES - ['excluded'], 130,
                                    detail: '共通教育＋専門基礎＋専門必修＋専門選択。自然系は全体でも上限2単位。')
    end

    def status(checks)
      return :needs_review if @ledger.notes.any? || checks.any? { |check| check.status == :needs_review }

      CreditCheck.status(checks.all? { |check| check.status == :satisfied }, false)
    end
  end
end

