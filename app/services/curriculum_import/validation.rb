# frozen_string_literal: true

module CurriculumImport
  # 下書きの便覧(document)を、公開する前に機械で突き合わせる。AIには聞かない。
  #
  # 上流はすべて、機械が PDF を推測したもの。ここは、確認画面を流し見る人が気づかない種類の誤りを拾う層。
  # 答えは [{ scope:, target:, reason:, blocking: }]。scope は科目(:course)・規則(:rule)・画面の表(:display)、
  # 文書全体やページに関わるもの(:document)。blocking は公開を止めるかどうか。
  #
  # 止めるか警告かの分け方:
  #  止める  学生に黙って誤りを言う(充足に倒れる・算入してはいけない単位を数える・要件や単位が画面から消える)もの、
  #          判定の時に落ちるもの、公開すると便覧を読み込めない(Catalogue が拒む)もの。
  #  警告    判定が必ず要確認・不足に倒れるもの、数字の食い違い、読み落としの疑い。学生には「確認が必要」と出るので
  #          安全側に倒れるが、人が一度目を通すべきもの。
  # 要確認は常に安全な結果なので、迷ったら警告に置いた。逆に、止める側に置くものは、止めた理由を直す手段が人にあること。
  class Validation
    CHECKS = [CourseChecks, RuleShape, RuleChecks, DisplayChecks, PageChecks].freeze

    # 下書きの Curriculum から作る。ページの状態(pages)は document には無いので、一緒に渡す。
    def self.for(curriculum)
      new(curriculum.document, pages: curriculum.pages)
    end

    def initialize(document, pages: [])
      @input = Input.new(document, pages)
    end

    def call
      @call ||= run
    end

    # 公開を止める問題が1つでもあるか。
    def blocking?
      call.any? { |finding| finding[:blocking] }
    end

    private

    def run
      findings = Findings.new
      @input.shape_problems.each do |scope, target, reason|
        findings.blocking(scope, target, "#{reason}。読めない形のため、検査できません。")
      end
      CHECKS.each { |checks| checks.new(@input, findings).run }
      probe(findings) unless findings.blocking?
      findings.to_a
    end

    # 上の検査がどれも止めていないのに、本物の読み込みと判定が落ちるなら、検査に抜けがある。理由を画面に出す。
    # 学生の画面が落ちる便覧を、「問題なし」として公開させないための最後の網。履修の無い空の学生で判定を一度回す。
    def probe(findings)
      catalogue = GraduationAssessment::Catalogue.new(@input.document)
      GraduationAssessment::Evaluation.new(catalogue).call([], [], [])
    rescue StandardError => e
      detail = e.is_a?(ArgumentError) ? e.message : "#{e.class}: #{e.message}"
      findings.blocking(:document, '便覧', "便覧として読み込めない、または判定できません: #{detail}")
    end
  end
end

