# frozen_string_literal: true

class GraduationAssessment
  class SpecialistChecks
    def initialize(catalogue, ledger)
      @catalogue = catalogue
      @ledger = ledger
      @credit = CreditCheck.new(ledger)
    end

    def call
      [mandatory_check] + required_credit_checks + elective_checks + [fusion_check]
    end

    private

    def mandatory_check
      mandatory = @catalogue.mandatory
      missing = mandatory.reject { |course| @ledger.acquired?(course) }
      metadata_missing = mandatory_metadata_missing?(mandatory)
      uncertain_keys = missing.pluck('key').intersect?(@ledger.uncertain_required)
      unknown = metadata_missing || @ledger.unknown_identity || uncertain_keys
      status = CreditCheck.status(missing.empty? && !metadata_missing, unknown)
      Check.new(id: 'required_all', label: '専門必修31科目すべて', status: status,
                counted_credits: @ledger.sum(Catalogue::REQUIRED.keys), required_credits: 57,
                missing_courses: missing.pluck('name'), source: Catalogue::REQUIRED_SOURCE,
                detail: mandatory_detail(mandatory.size, missing.size))
    end

    def mandatory_metadata_missing?(mandatory)
      mandatory.size != 31 || mandatory.any? { |course| Catalogue::REQUIRED.exclude?(course['category']) }
    end

    def mandatory_detail(count, missing)
      "31科目それぞれの修得を確認。科目表の必修#{count}科目中#{count - missing}科目を確認。" \
        '余剰単位による代用は不可。'
    end

    def required_credit_checks
      groups = Catalogue::REQUIRED.map do |category, (label, credits)|
        @credit.call(category, label, [category], credits, source: Catalogue::REQUIRED_SOURCE)
      end
      groups + [required_total_check]
    end

    def required_total_check
      @credit.call('required_total', '専門必修の合計', Catalogue::REQUIRED.keys, 57,
                   source: Catalogue::REQUIRED_SOURCE)
    end

    def elective_checks
      [
        @credit.call('elective_inner', '数学基礎選択＋アドバンスト＋関連', Catalogue::INNER, 22,
                     detail: '専門選択37単位の内数。工学融合・自由科目はこの22単位に含めません。'),
        @credit.call('elective_total', '専門選択の合計', Catalogue::ELECTIVE, 37)
      ]
    end

    def fusion_check
      providers = @ledger.grouped_credits('fusion', 'provider').slice(*Catalogue::PROVIDERS)
      @credit.call('fusion_provider', '同一の他コースが提供する工学融合', ['fusion'], 4,
                   counted: providers.values.max || Catalogue::ZERO, review: @ledger.fusion_provider_unknown,
                   detail: '自コース提供分は不可。他コースを合算せず、同一提供コースから4単位以上。')
    end
  end
end

