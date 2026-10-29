# frozen_string_literal: true

class GraduationAssessment
  # 便覧の規則を並び順に解釈して判定を組み立てる。判定の内容はコードではなく便覧のデータが決める。
  class Evaluation
    def initialize(catalogue)
      @catalogue = catalogue
      @ledger = Ledger.new(catalogue)
    end

    # reconcile（経路の混在の解消）→ 調整（上限の打ち切り）→ 判定、の順に回す。
    # 判定は check だけを呼ぶ。evaluate を重ねて呼ぶと、要確認の注記が科目ごとに二重に積まれる。
    def call(completed, future, unresolved)
      EntryNormalizer.new(@catalogue, @ledger).call(completed, future, unresolved)
      @catalogue.conditions.each { |rule| rule.reconcile(@catalogue, @ledger) }
      @catalogue.adjustments.each { |rule| rule.apply(@catalogue, @ledger) if rule.respond_to?(:apply) }
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

