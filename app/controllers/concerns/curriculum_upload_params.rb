# frozen_string_literal: true

# 便覧PDFのアップロードフォーム(/requirements の取り込み)が送る値を、下書きの属性に直す。
# 識別名(slug)は送られない。Curriculum が学部名・学科コース名から決める。
module CurriculumUploadParams
  extend ActiveSupport::Concern

  # 学部名・学科コース名のプルダウンで「その他（新しく登録する）」を選んだ印。名前としては保存しない。
  # 空文字にしないのは、「何も選んでいない」と区別するため。選ぶと、横の自由入力欄(*_name_other)の値が名前になる。
  NEW_PROGRAM = '__other__'

  private

  def upload_params
    @upload_params ||= begin
      raw = params[:curriculum]
      # ?curriculum=x のように、ハッシュでない値が来ても落とさず、空の入力として扱う
      raw = ActionController::Parameters.new unless raw.is_a?(ActionController::Parameters)
      # slug は受けない。画面に欄が無く、課程を取り違える入力口になるので、送られても読まない。
      raw.permit(:admission_year, :faculty_name, :department_name, :faculty_name_other, :department_name_other,
                 :course_name, :course_name_other, :file)
    end
  end

  # 下書きの属性。学部名は、プルダウンの選択か、「その他」を選んだときの自由入力のどちらか。
  # 学科・コース名も同じ(選択か自由入力)だが、Curriculum#department_name は1つの文字列で持つので、
  # 画面では別のプルダウンでも、ここで結んで渡す(コースの無い学科は、学科名だけになる)。
  # 「その他」を選んだ自由入力も、選択と同じ検証(必須・正規化)を通る。
  def curriculum_attributes
    { admission_year: upload_params[:admission_year], faculty_name: chosen_name(:faculty_name),
      department_name: [chosen_name(:department_name), chosen_name(:course_name)].compact_blank.join(' ') }
  end

  def chosen_name(field)
    return upload_params[field] unless upload_params[field] == NEW_PROGRAM

    typed = upload_params[:"#{field}_other"]
    # 選んだ印そのものを打たれても名前にしない。保存すると、実在の課程と「その他」が同じ値の選択肢になり、見分けが付かなくなる。
    typed.to_s.squish == NEW_PROGRAM ? nil : typed
  end
end

