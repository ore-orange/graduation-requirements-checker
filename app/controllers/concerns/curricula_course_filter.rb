# frozen_string_literal: true

# 番号で区分が決まる科目を、下書きから外す操作(③ 科目表を確認する の節のボタン)。
# 科目ごとの保存(CurriculaCourses)とは違い、便覧全体に効く操作なので別に置く。
module CurriculaCourseFilter
  extend ActiveSupport::Concern

  # 番号で区分が決まり、読みとも一致する科目を、文書から外す。要件表の保存(候補の採用)を経由せず、作業中の下書きや、
  # 公開済みを複製した下書き(全科目が確認済み)にも使える入口。人が押した操作なので、確認済み・手で足した科目も外す
  # (drop_confirmed)。押す前に画面が件数を見せる。便覧全体に効くので、区分は絞らない(only を渡さない)。
  # 多くの行がまとめて変わるので、Turbo にはせず素直に画面を開き直す。ロックの中で公開済みに変わっていないかも確かめる。
  def filter_courses
    dropped = []
    published = false
    @curriculum.with_lock do
      published = @curriculum.published?
      unless published
        document = @curriculum.document.deep_dup
        dropped = CurriculumImport::CoursePrune.call(document, drop_confirmed: true)
        @curriculum.update!(document: document) if dropped.any?
      end
    end
    return redirect_to requirements_location, alert: published_alert, status: :see_other if published

    redirect_to curriculum_path(@curriculum, anchor: 'course-review'), status: :see_other, **filter_flash(dropped)
  end

  private

  # 外した件数を知らせる。確認済みの科目は、人が見た印を捨てることになるので、内数も出す。
  def filter_flash(dropped)
    return { notice: '外せる科目はありませんでした。' } if dropped.empty?

    confirmed = dropped.count { |course| CurriculumImport::CourseEdit.confirmed?(course) }
    { notice: "番号で区分が決まる科目#{dropped.size}科目を外しました(うち確認済み#{confirmed}科目)。" }
  end
end

