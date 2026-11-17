# frozen_string_literal: true

# ページの指定の保存(CurriculaController#update)を、Turbo Stream で受けたときの応答。
# 画面の「この指定で読み取る」は、保存を fetch で送り、応答の警告を見せてから読み取りに入る。
# 警告は、保存済みの document と pages から作る(保存前の状態から別に作ると、同じ判断を画面にも持つことになる)。
module CurriculaPagesUpdate
  extend ActiveSupport::Concern

  private

  def redirect_after_update(notice)
    return redirect_to requirements_location, alert: published_alert, status: :see_other if notice == published_alert
    return redirect_to @curriculum, alert: notice, status: :see_other if notice.is_a?(String)

    redirect_to @curriculum, notice: saved_notice, status: :see_other
  end

  # 保存できたら、全ページの行を差し替える(読む種別になった行は、読み取りの宛先を持って返る)。
  # 保存できなかったら行は触らず(人が選んだ指定を、保存値に戻さない)、理由だけを返す。
  def render_update_stream(notice)
    @error = notice if notice.is_a?(String)
    @warnings = @error ? [] : save_warnings
    status = if @error.nil? then :ok
             elsif notice == published_alert then :conflict
             else :unprocessable_content
             end
    render :update, status: status
  end

  # 保存の応答が見せる警告。画面は、空でなければ読み取りの前に確認を出す。
  # 保存済みの document と pages から作るので、保存前の状態から別に作らない(同じ判断を画面に持たせない)。
  def save_warnings
    [(saved_notice if @withdrawn_pages.present?), *reread_warnings].compact
  end

  # 画面が読み取りに入るページの、読み直しの確認。「全部読む」・「この指定で読み取る」は、読む種別で読み終わっていないページ。
  # 行の「読む」(only_page)は、そのページだけ(読み終わっていても読み直すので、状態は問わない)。
  def reread_warnings
    only = params[:only_page].presence&.to_i
    to_read = @curriculum.pages.select do |page|
      next false unless Curriculum::READABLE_PAGE_KINDS.include?(page['kind'])

      only ? page['page'] == only : page['status'] != 'read'
    end
    to_read.filter_map { |page| CurriculumImport::RereadWarning.for(@curriculum.document, page) }
  end
end

