# frozen_string_literal: true

module CurriculumImport
  # 下書きの便覧を公開する関門。公開は、その文書が学生に「卒業できます」と言い始める瞬間で、ここより前はすべてやり直せる。
  # 誤読した要件が、単位の足りない学生に充足を言わないよう、危ない文書は止める。止めるときは、事務の人が直せる理由を言う
  # (直せない理由で止める関門は、止めない関門と同じに役立たない。理由を直す手段が、確認画面にあること)。
  #
  # 「公開できるか」「公開した文書は何を持つか」は、このクラスと PublishedDocument の1か所で決める。
  # 画面のボタンも、Curriculum#publishable?・#publish! も、すべてここを通る(別々に判定して食い違わせない)。
  #
  # 止める(blocking_reasons)
  #  - すでに公開済み・同じ識別名と入学年度の公開済みが別にある(差し替えは、明示したときだけ)
  #  - 確認し終えていない科目が1つでもある(確認画面の「確認済み」と同じ定義。CourseEdit.confirmed?)
  #  - 機械の突き合わせ(Validation)が止める指摘。下書きのままと、公開する形にしたあとの文書の両方を検める
  #    (落とした欄を規則が当てにしていないか、公開後の文書が読み込め、判定が走るか)
  # 警告(warnings)は止めないが、読んだ人の確認(acknowledged)が要る。警告は、見落とすと学生に「要確認」「不足」を言い続ける
  # 種類(科目表の読み落としなど)で、公開後は学生の画面にしか出ない。一覧を見せ、見たと答えてから公開させる。
  # 確認の答えは警告の一覧の指紋(digest)で、画面を開いたあとに警告が変わったら通らない。
  class Publication
    # 公開できなかった。reasons は人に見せる文。
    class Refused < StandardError
      attr_reader :reasons

      def initialize(reasons)
        @reasons = reasons
        super("公開できません: #{reasons.first(3).join(' / ')}#{" ほか#{reasons.size - 3}件" if reasons.size > 3}")
      end
    end

    # 指摘が指す場所を、確認画面の見出しの名前で言う(どこを直すかが分かるように)。
    SCOPE_LABELS = { course: '科目表の確認', rule: '要件表の確認・規則', display: '要件表の確認・画面の表',
                     document: '文書全体' }.freeze
    EXAMPLE_COUNT = 5

    attr_reader :curriculum

    # 行をロックした上で判定し、公開する。差し替え(replace)は、同じ識別名・入学年度の公開済みを下書きに戻し、その便覧を
    # 使っていた学生を新しい便覧に付け替える(1本の update_all)。どれかが失敗したら、すべて元に戻る。
    # ページ画像は、DBが確定してから消す(失敗して戻ったときに、画像まで失わないように)。
    def self.publish!(curriculum, acknowledged: nil, replace: false)
      curriculum.with_lock do
        publication = new(curriculum, replace: replace)
        publication.refuse_unless_ready!(acknowledged)
        publication.apply!
      end
      FileUtils.rm_rf(curriculum.images_dir)
      curriculum
    rescue ActiveRecord::RecordNotUnique
      # 判定のあとに、別の人が同じ課程・入学年度を公開した。索引が守るので、落とさず理由にする。
      raise Refused, ["同じ学部・学科コースの#{curriculum.admission_year}年度入学の公開済みの便覧が、先に公開されました。"]
    end

    def initialize(curriculum, replace: false)
      @curriculum = curriculum
      @replace = replace
    end

    # 公開する文書。下書きの document から、作業用の欄を落としたもの。
    def document
      @document ||= PublishedDocument.build(curriculum.document, slug: curriculum.slug,
                                                                 admission_year: curriculum.admission_year,
                                                                 faculty_name: curriculum.faculty_name,
                                                                 department_name: curriculum.department_name)
    end

    def publishable? = blocking_reasons.empty?

    def blocking_reasons
      @blocking_reasons ||=
        if curriculum.published?
          ['この便覧はすでに公開済みです。']
        else
          [conflict_reason, unconfirmed_reason, *blocking_findings].compact.uniq
        end
    end

    # 止めないが、読んで確認してもらう指摘。下書きの指摘から出す(確認画面と同じ。確認済みの科目の食い違いは出さない)。
    def warnings
      @warnings ||= draft_findings.reject { |finding| finding[:blocking] }.map { |finding| describe(finding) }.uniq
    end

    # 警告の一覧の指紋。画面が持ち回り、公開のときに、見たものと同じ一覧かを確かめる。
    def digest
      Digest::SHA256.hexdigest(warnings.to_json)[0, 16]
    end

    def acknowledged?(answer)
      warnings.empty? || answer.to_s == digest
    end

    # 差し替えの相手。同じ識別名・入学年度で、いま学生に使われている公開済み。
    def twin
      return @twin if defined?(@twin)

      @twin = Curriculum.published.where(slug: curriculum.slug, admission_year: curriculum.admission_year)
                        .where.not(id: curriculum.id).lock.first
    end

    # 差し替えの相手を使っている学生の数。
    def twin_student_count = twin ? Student.where(curriculum_id: twin.id).count : 0

    def refuse_unless_ready!(acknowledged)
      raise Refused, blocking_reasons unless publishable?
      return if acknowledged?(acknowledged)

      raise Refused, ["警告が#{warnings.size}件あります。内容を確かめて、確認したことを伝えてから公開してください(警告は画面を開いたときから変わっているかもしれません)。"]
    end

    def apply!
      twin_id = twin&.id
      demote_twin if twin
      curriculum.update!(document: document, title: document['title'].presence || curriculum.title, pages: [],
                         source_filename: nil, import_error: nil, published_at: Time.current)
      return unless twin_id

      Student.where(curriculum_id: twin_id).update_all(curriculum_id: curriculum.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    private

    # 差し替えで下書きに戻る、もとの公開済み。公開の関門を一度通った文書なので、科目は確認済みのまま戻す(Duplicate と同じ理由。
    # 戻すたびに484科目を確認し直させては、差し替えという機能そのものが使われなくなる)。
    def demote_twin
      document = twin.document.deep_dup
      CourseEdit.confirm_all!(document)
      twin.update_columns(document: document, published_at: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    def draft_findings
      @draft_findings ||= Validation.for(curriculum).call
    end

    # 下書きの指摘に加えて、公開する形にした文書も同じ検査にかける。同じ指摘は1つにまとめる。
    def blocking_findings
      published = Validation.new(document, pages: curriculum.pages).call
      (draft_findings + published).select { |finding| finding[:blocking] }.map { |finding| describe(finding) }
    end

    def describe(finding)
      "【#{SCOPE_LABELS.fetch(finding[:scope], '文書全体')}】#{finding[:target]}: #{finding[:reason]}"
    end

    def conflict_reason
      return if @replace || twin.nil?

      "同じ学部・学科コースの#{curriculum.admission_year}年度入学の公開済みの便覧が既にあります" \
        "(学生#{twin_student_count}人が使っています)。" \
        '差し替えて公開すると、その便覧は下書きに戻り、学生の判定は新しい便覧に切り替わります。差し替えるときは「差し替えて公開」を選んでください。'
    end

    def unconfirmed_reason
      # 確認の印は公開する文書から落とすので、下書きのほうを見る。
      courses = curriculum.document.is_a?(Hash) ? Array(curriculum.document['courses']).grep(Hash) : []
      pending = courses.reject { |course| CourseEdit.confirmed?(course) }
      return if pending.empty?

      names = pending.first(EXAMPLE_COUNT).map { |course| course['number'].presence || course['name'] || course['key'] }
      "【科目表の確認】確認し終えていない科目が#{pending.size}件あります(全#{courses.size}件中。例: #{names.join('、')})。" \
        'PDFと見比べて、合っている科目は「確認した」を、違う科目は直してから、押してください。'
    end
  end
end

