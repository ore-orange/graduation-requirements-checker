# frozen_string_literal: true

module CurriculumImport
  # 区分ごとの「まとめて確認する」。484科目を1つずつ確認させるのは確認ではなく作業になるので、
  # 区分の節(CoursesReview::Section)に出ている、確認し終えていない科目をまとめて確認済みにする。
  #
  # 対象と指紋は CoursesReview が決める1か所(CoursesReview#section_pending・#section_revision)。
  # 画面のボタンが見せる区分の中身と、ここが確認する中身がそろう(どちらも同じ CoursesReview の節を見る)。
  # 最初に見る科目は、その節の rows に入らないので、対象にならない(まとめて確認するのは、PDFと見比べるまでもない、
  # 素直な科目だけ)。食い違い・突き合わせの指摘・要確認の理由に加えて、承認の注記があとから付いた科目(review_again)も
  # 最初に見る科目の印なので対象にならない。承認が変わったことに人が気づかないまま素通りさせないため。
  #
  # 1科目ずつの確認(CourseEdit)と同じ意味で確認する(値は変えない。確認済みの印を付け、送った confirmed の分だけ、
  # もう一度見る印があれば外す。対象は review_again の無い科目だけなので、実際にはここで外れることはない)。
  # 画面を開いたときの、この区分の指紋(rev)を送り返す。開いたあとに区分の中身が変わっていれば
  # (読み取りの続き、ほかの確認・追加・削除、区分の付け替え)、1件も確認せず断る(1科目の確認が rev で守るのと同じ理屈)。
  class BulkConfirm
    Result = Struct.new(:ok, :confirmed, :message, keyword_init: true) do
      def ok? = ok
    end

    def initialize(curriculum, category:, rev:)
      @curriculum = curriculum
      @category = category.to_s
      @rev = rev.to_s
    end

    # 行をロックした中で呼ぶこと。
    def call
      current_rev = review.section_revision(@category)
      return failure('この区分は見つかりません。画面を開き直してください。') if current_rev.nil?
      return stale unless @rev.present? && @rev == current_rev

      pending = review.section_pending(@category)
      pending.each { |row| confirm(row.course) }
      success(pending.size)
    end

    private

    # courses_review ヘルパと同じ組み立て。突き合わせ(Validation)を2回走らせない(section_revision・section_pending の両方で使う)。
    def review
      @review ||= CoursesReview.new(RequirementsReview.new(@curriculum))
    end

    def confirm(course)
      CourseEdit.new(@curriculum, key: course['key'], confirmed: true).call
    end

    def success(count)
      message = count.zero? ? 'この区分は、もう全部確認済みです。' : "#{count}科目をまとめて確認済みにしました。"
      Result.new(ok: true, confirmed: count, message: message)
    end

    def stale
      failure('この区分は、画面を開いたあとに変わっています(読み取りや、ほかの確認・追加・削除)。何も確認していません。' \
              '画面を開き直して、もう一度試してください。')
    end

    def failure(message) = Result.new(ok: false, confirmed: 0, message: message)
  end
end

