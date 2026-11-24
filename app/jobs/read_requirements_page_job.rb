# frozen_string_literal: true

# 要件表の1ページを、画面のリクエストとは切り離して読み取る。Gemini の応答に数十秒〜数分かかるため。
# 結果(読み取り済み・失敗)は下書きの pages に書き、画面は状態を問い合わせて表示を更新する。
class ReadRequirementsPageJob < ApplicationJob
  queue_as :default

  def perform(curriculum_id, page)
    curriculum = Curriculum.drafts.find_by(id: curriculum_id)
    # 読み取りの間に下書きが消された・公開された場合は、何もしない。
    return unless curriculum

    CurriculumImport::ReadRequirementsPage.call(curriculum, page)
  rescue StandardError => e
    # 想定外のエラーでも「読み取り中」のまま残さない。理由は種類だけを出す(本文に何が入るか分からないため)。
    Rails.logger.error("要件表の読み取りに失敗しました: #{e.class}: #{e.message}")
    mark_failed(curriculum, page, '読み取りの途中で問題が起きました。もう一度「読み直す」を押してください。') if curriculum
  end

  private

  def mark_failed(curriculum, page, message)
    curriculum.with_lock do
      pages = curriculum.pages.map do |entry|
        entry['page'] == page ? entry.merge('status' => 'failed', 'error' => message) : entry
      end
      curriculum.update!(pages: pages)
    end
  end
end

