# frozen_string_literal: true

class GraduationAssessment
  class BasicAlternatives
    attr_reader :calculus_ambiguous, :physics_ambiguous

    def initialize(catalogue, ledger)
      @requirements = catalogue.requirements
      @ledger = ledger
    end

    def call
      reconcile_calculus
      reconcile_physics
      self
    end

    private

    def reconcile_calculus
      paths = @requirements.fetch('calculus_paths')
      selected = paths.select { |path| path.any? { |role| @ledger.selected_role?(role) } }
      return unless selected.many?

      @calculus_ambiguous = true
      @ledger.quarantine_roles(paths.flatten, '微分積分学の系列が混在・重複しており、組合せと重複算入の確認が必要')
    end

    def reconcile_physics
      roles = @requirements.fetch('physics_roles')
      return unless roles.many? { |role| @ledger.selected_role?(role) }

      @physics_ambiguous = true
      @ledger.quarantine_roles(roles, '物理学の代替科目を重複して修得・予定しており、重複算入の確認が必要')
    end
  end
end

