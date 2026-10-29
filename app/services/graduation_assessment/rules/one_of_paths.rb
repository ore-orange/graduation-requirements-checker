# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 役割（role）の組で表した経路のうち、どれか1つを丸ごと満たせばよい。
    class OneOfPaths < Base
      def evaluate(catalogue, ledger)
        paths = definition.fetch('paths')
        remaining = paths.map { |path| path.reject { |role| acquired?(catalogue, ledger, role) } }
        # reconcile の呼び忘れで混在を充足と判定しないよう、evaluate 単独でも混在なら充足にしない。
        mixed = mixed?(ledger)
        satisfied = remaining.any?(&:empty?) && !mixed
        Outcome.new(satisfied: satisfied, review: mixed || uncertain?(catalogue, ledger, paths.flatten),
                    counted: nil, missing: satisfied ? [] : missing_names(catalogue, remaining))
      end

      # 複数の経路に算入済みの役割があるとき、組合せと重複算入を確認できるまで全役割を算入から外す。
      def reconcile(_catalogue, ledger)
        return unless mixed?(ledger)

        ledger.quarantine_roles(definition.fetch('paths').flatten, review_note)
      end

      private

      # 2つ以上の経路に、算入済みの役割がある。
      def mixed?(ledger)
        definition.fetch('paths').many? { |path| path.any? { |role| ledger.selected_role?(role) } }
      end

      # 学生に見せる文面は便覧ごとに違うので定義に持たせる。無くても要確認にすることは変わらない。
      def review_note
        definition['review_note'].presence || "#{label}の選択が重複しており、確認が必要"
      end

      def acquired?(catalogue, ledger, role)
        catalogue.role_candidates(role).any? { |course| ledger.acquired?(course) }
      end

      def uncertain?(catalogue, ledger, roles)
        ledger.unknown_identity || roles.intersect?(ledger.uncertain_roles) ||
          roles.any? { |role| catalogue.role_candidates(role).empty? }
      end

      def missing_names(catalogue, remaining)
        remaining.flatten.uniq.flat_map do |role|
          names = catalogue.role_names(role)
          names.empty? ? ["指定科目（#{role}：科目表未確認）"] : names
        end
      end

      # 選択経路を勝手に一つへ絞らず、各経路の「かつ」と「または」を示す。
      def detail(catalogue, _outcome, _status)
        definition.fetch('paths').map do |path|
          path.map { |role| catalogue.role_names(role).join('／') }.join(' ＋ ')
        end.join(' または ')
      end
    end
  end
end

