# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 役割(roles)の組で表した経路のうち、どれか1つを丸ごと満たすか。
    # 例: 微分積分学は「STⅠ＋STⅡ」または「入門Ⅰ＋入門Ⅱ」。
    #
    # 経路が複数あり、2つ以上の経路に算入済みの科目があるときは、組合せと重複算入を確認できるまで、
    # その規則の全役割を算入から外し、review_note を注記する(reconcile)。どれか1つを勝手に選ばない。
    class OneOfPaths < Base
      def paths = definition.fetch('paths')
      def roles = paths.flatten.uniq

      def reconcile(_catalogue, ledger)
        return unless paths.many?

        selected = paths.select { |path| path.any? { |role| ledger.selected_role?(role) } }
        return unless selected.many?

        ledger.ambiguous_rules << id
        ledger.quarantine_roles(roles, definition.fetch('review_note'))
      end

      def check(catalogue, ledger)
        ambiguous = ledger.ambiguous_rules.include?(id)
        missing = paths.map { |path| path.reject { |role| acquired?(catalogue, ledger, role) } }
        satisfied = missing.any?(&:empty?) && !ambiguous
        unknown = ambiguous || uncertain?(catalogue, ledger)
        build_check(status: Rules.status(satisfied, unknown), counted: nil, required: nil,
                    missing: satisfied ? [] : missing_names(catalogue, missing), detail: description(catalogue))
      end

      private

      def acquired?(catalogue, ledger, role)
        catalogue.role_candidates(role).any? { |course| ledger.acquired?(course) }
      end

      def uncertain?(catalogue, ledger)
        ledger.unknown_identity || roles.intersect?(ledger.uncertain_roles) ||
          roles.any? { |role| catalogue.role_candidates(role).empty? }
      end

      def missing_names(catalogue, missing)
        missing.flatten.uniq.flat_map do |role|
          names = catalogue.role_names(role)
          names.empty? ? ["指定科目（#{role}：科目表未確認）"] : names
        end
      end

      # 経路を1つに絞らず、各経路の「かつ」と「または」を示す。
      def description(catalogue)
        paths.map { |path| path.map { |role| catalogue.role_names(role).join('／') }.join(' ＋ ') }.join(' または ')
      end
    end
  end
end

