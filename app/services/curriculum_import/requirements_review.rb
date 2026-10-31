# frozen_string_literal: true

module CurriculumImport
  # 要件表の確認画面が見せるもの。document を画面が引ける形に整え、突き合わせの結果(Validation)を結びつける。
  #
  # 下書きの document は AI が書いたものを人が直したもので、欄が壊れていることがある(Validation::Input が読める形にする)。
  # 画面がそれで落ちると、壊れた下書きを直す画面そのものが開けなくなるので、画面は Input を通して読む。
  class RequirementsReview
    SCOPE_NAMES = { course: '科目', rule: '規則', display: '画面の表', document: '文書全体' }.freeze

    # 保存できなかった送信の、送られたままの入力(欄の名前 → 値)。画面を同じ入力で開き直すために持つ。
    # 画面のフォームごとに、持ち主を見分ける(要件表のフォームは form=requirements を送る)。
    class Submission
      def initialize(pairs)
        @values = pairs.group_by(&:first).transform_values { |entries| entries.map(&:last) }
      end

      def main_form? = @values['form'] == ['requirements']

      delegate :key?, to: :@values

      def value(name) = @values[name]&.last

      def values(name) = @values.fetch(name, [])
    end

    attr_reader :curriculum, :problems

    delegate :categories, :rules, :groups, :subtotals, :display, :courses, to: :input

    # submission は、保存できなかった送信の入力。problems と touched は RequirementsEdit の結果。
    def initialize(curriculum, submission: nil, problems: [], touched: [])
      @curriculum = curriculum
      @submission = submission
      @problems = problems
      @touched = touched
    end

    # 入力欄の値。保存できなかった送信の入力があれば、それを残す(1つの打ち間違いで、打った全部を失わせない)。
    def field_value(name, default)
      @submission&.key?(name) ? @submission.value(name) : default
    end

    # チェックの箱の状態。送信が要件表のフォームからなら、そこで入っていた箱だけが入っている(入っていない箱は外れている)。
    def field_checked?(name, value, default)
      @submission&.main_form? ? @submission.values(name).include?(value) : default
    end

    def problems_for(kind, id) = problems.select { |problem| problem.kind == kind && problem.id == id.to_s }

    # 値を変えた項目と、問題があった項目は、「直す」を開いたまま見せる(どこを直したか・どこが問題かを隠さない)。
    def open?(kind, id) = @touched.include?([kind, id.to_s])

    # 読み取った要件表が何も無い下書き(まだ読んでいない)は、確認するものが無い。突き合わせの「何も無い」を並べない。
    def started?
      categories.any? || rules.any? || groups.any? || read_requirements_page?
    end

    def findings
      @findings ||= Validation.for(curriculum).call
    end

    def blocking?
      findings.any? { |finding| finding[:blocking] }
    end

    def blocking_findings = findings.select { |finding| finding[:blocking] }

    def warning_findings = findings.reject { |finding| finding[:blocking] }

    # 項目(規則の id・章や行の id)に結びつく突き合わせの結果。表の行の下に出す。
    def findings_for(scope, target)
      findings.select { |finding| finding[:scope] == scope && finding[:target] == target.to_s }
    end

    def scope_name(scope) = SCOPE_NAMES.fetch(scope, scope.to_s)

    # 画面を開いたときの中身の指紋。保存のときに送り返され、開いたあとに中身が変わっていないかを確かめる。
    def revision = RequirementsEdit.revision(curriculum.document)

    def cards = @cards ||= Annotations.cards(curriculum.document, curriculum.pages)

    delegate :category_label, to: :input

    delegate :category_keys, :uncounted_category_keys, to: :input

    def course_count(category) = input.courses_in(category).size

    def rule_ids = input.rules.pluck('id')

    # 役割(経路が名指しするキー)を持つ科目の名前。規則が名指しする役割に科目が無いと、その規則は必ず要確認になる。
    def role_names(role) = courses.select { |course| Array(course['roles']).include?(role) }.pluck('name')

    def rows_of(group) = Array(group['rows']).grep(Hash)

    def removed_items
      Array(curriculum.document.is_a?(Hash) ? curriculum.document[DraftMerge::REMOVED] : nil).grep(Hash)
    end

    private

    def input
      @input ||= Validation::Input.new(curriculum.document, curriculum.pages)
    end

    # 規則も区分も表も無くても、読み取りが終わっていれば(承認の警告や欠けは)見せる。
    def read_requirements_page?
      curriculum.pages.any? { |page| page['status'] == 'read' && page['kind'] == 'requirements' }
    end
  end
end

