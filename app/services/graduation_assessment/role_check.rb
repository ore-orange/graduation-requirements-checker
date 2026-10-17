# frozen_string_literal: true

class GraduationAssessment
  class RoleCheck
    def initialize(catalogue, ledger)
      @catalogue = catalogue
      @ledger = ledger
    end

    def call(id, label, paths, review: false)
      missing = paths.map { |path| path.reject { |role| acquired?(role) } }
      satisfied = missing.any?(&:empty?) && !review
      unknown = review || uncertain?(paths.flatten)
      Check.new(id: id, label: label, status: CreditCheck.status(satisfied, unknown),
                counted_credits: nil, required_credits: nil,
                missing_courses: satisfied ? [] : missing_names(missing), source: Catalogue::SOURCE,
                detail: path_description(paths))
    end

    private

    def acquired?(role)
      @catalogue.role_candidates(role).any? { |course| @ledger.acquired?(course) }
    end

    def uncertain?(roles)
      @ledger.unknown_identity || roles.intersect?(@ledger.uncertain_roles) ||
        roles.any? { |role| @catalogue.role_candidates(role).empty? }
    end

    def missing_names(paths)
      paths.flatten.uniq.flat_map do |role|
        names = @catalogue.role_names(role)
        names.empty? ? ["指定科目（#{role}：科目表未確認）"] : names
      end
    end

    def path_description(paths)
      # 選択経路を勝手に一つへ絞らず、各経路の「かつ」と「または」を示す。
      descriptions = paths.map do |path|
        path.map { |role| @catalogue.role_names(role).join('／') }.join(' ＋ ')
      end
      descriptions.join(' または ')
    end
  end
end

