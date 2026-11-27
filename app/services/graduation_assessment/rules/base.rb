# frozen_string_literal: true

class GraduationAssessment
  module Rules
    # 条件の共通部分。outcome(入れ子でも使う結果)と check(画面に出すチェック)を持つ。
    class Base
      attr_reader :definition

      def initialize(definition)
        @definition = definition
      end

      def id = definition['id']
      def label = definition['label'] || id
      def source = definition['source']

      # この条件の中にある grouped_max(グループを決められない科目に注記を付けるため、取り込み時に使う)。
      def grouped_rules = []

      # 入れ子の条件の値を、id で引けるようにする(any_of の説明文に差し込むため)。
      def counted_values(_catalogue, _ledger) = {}

      private

      def build_check(status:, counted:, required:, missing:, detail:)
        Check.new(id: id, label: label, status: status, counted_credits: counted, required_credits: required,
                  missing_courses: missing, source: source, detail: detail)
      end

      # 単位を数える条件の説明。便覧の detail(前半)に、算入と必要単位、不足や未確定を足す。
      def credit_detail(counted, required, status)
        text = "#{definition['detail']} 確認済み算入#{counted.to_s('F')}／必要#{required}単位。"
        deficit = [BigDecimal(required.to_s) - counted, Catalogue::ZERO].max
        text += "不足#{deficit.to_s('F')}単位。" if status == :unmet
        text += '未確認事項により不足の確定はできません。' if status == :needs_review
        text.strip
      end

      # 単位を数える条件の、画面に出すチェック。
      def credit_check(catalogue, ledger)
        result = outcome(catalogue, ledger)
        status = Rules.status(result.satisfied, result.review)
        required = definition.fetch('required_credits')
        build_check(status: status, counted: result.counted, required: required, missing: [],
                    detail: credit_detail(result.counted, required, status))
      end
    end
  end
end

