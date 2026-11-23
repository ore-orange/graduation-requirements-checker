# frozen_string_literal: true

class GraduationAssessment
  # 便覧の rules を並び順に解釈して、1つの時点(実績か見込み)の判定を作る。
  # 区分名・必要単位・文面はコードに持たず、すべて rules から読む。
  class Evaluation
    def initialize(catalogue)
      @catalogue = catalogue
      @ledger = Ledger.new(catalogue)
    end

    def call(completed, future, unresolved)
      EntryNormalizer.new(@catalogue, @ledger).call(completed, future, unresolved)
      # 算入を変える処理を、条件を評価する前に済ませる。経路の重複を外してから、上限で打ち切る。
      @catalogue.path_rules.each { |rule| rule.reconcile(@catalogue, @ledger) }
      @catalogue.caps.each { |rule| rule.apply(@ledger) }
      checks = @catalogue.conditions.map { |rule| rule.check(@catalogue, @ledger) }
      Snapshot.new(status: status(checks), counted_credits: @ledger.total, checks: checks.freeze,
                   review_notes: @ledger.notes.uniq.freeze, course_results: @ledger.course_results)
    end

    private

    def status(checks)
      return :needs_review if @ledger.notes.any? || checks.any? { |check| check.status == :needs_review }

      Rules.status(checks.all? { |check| check.status == :satisfied }, false)
    end
  end
end

