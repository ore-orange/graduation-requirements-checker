# frozen_string_literal: true

# 卒業要件の確認。学部・学科コース・入学年度を選んでから、その便覧に書かれた章・規則を見せる読み取り専用の画面。
# 学生の便覧ではなく、選んだ組み合わせから便覧を引く。だから学生(StudentWorkspace)は読み込まず、
# マスタを書き換える画面と同じ「ローカルの開発・テスト環境に限る」守りだけを使う。
class RequirementsController < ApplicationController
  include LocalAccessOnly

  # 年度は Curriculum の検証(1..9999)と同じ範囲だけを受ける。桁あふれの値をそのまま SQL に渡さないため。
  YEAR_RANGE = 1..9999
  # 指定に含まれる文字列の長さの上限。画面に「ありません」と出すときに、巨大な値をそのまま返さないため。
  MAX_PARAM_LENGTH = 100

  helper_method :selection_complete?, :selection_given?

  # 選択の結果は3通りで、どれも @selection（選んだ値）を持つ。
  #   公開済みがある … @published（レコード）と、判定に使う @curriculum（文書）・@catalogue。下書きがあれば @drafts も。
  #   下書きだけがある … @drafts
  #   どちらも無い … 何も持たない（画面が「まだありません」と PDF の入口を出す）
  # 3つ揃っていなければ便覧は引かない（最初の画面は、選択だけを出す）。
  def show
    load_options
    @selection = { faculty: text_param(:faculty), department: text_param(:department),
                   admission_year: text_param(:admission_year) }
    @drafts = []
    return unless selection_complete?

    resolve_selection
  end

  private

  # 3つとも指定されているか。揃っているときだけ便覧を探す。
  def selection_complete? = @selection.values.all?(&:present?)

  # 1つでも指定されているか。揃っていないときに、足りないことを伝えるために見る。
  def selection_given? = @selection.values.any?(&:present?)

  # 選択肢は、実在する便覧から作る（公開済みも下書きも。下書きだけの年度・コースも選べるように）。
  # 学部名・学科コース名を持たない便覧は、選んでも引けないので入れない。
  def load_options
    # where.not に2列を渡すと「2列とも空、ではない」になり、片方だけ空の行が残ってしまう。1列ずつ除く。
    names = Curriculum.where.not(faculty_name: [nil, '']).where.not(department_name: [nil, ''])
    @faculty_options = names.distinct.order(:faculty_name).pluck(:faculty_name)
    # 学科コースは学部ごとにまとめて出す（学部を選んでから学科コースを選ぶ順に読めるように）。JS は使わない。
    @department_options = names.distinct.order(:faculty_name, :department_name)
                               .pluck(:faculty_name, :department_name).group_by(&:first)
                               .transform_values { |pairs| pairs.map(&:last) }
    @year_options = names.distinct.order(admission_year: :desc).pluck(:admission_year)
  end

  # 選んだ組み合わせの便覧を探す。変な値（無い学部・数字でない年度）は、何も見つからないだけで、例外にも別の便覧にもならない。
  def resolve_selection
    year = Integer(@selection[:admission_year], 10, exception: false)
    return unless year && YEAR_RANGE.cover?(year)

    candidates = Curriculum.where(faculty_name: @selection[:faculty], department_name: @selection[:department],
                                  admission_year: year)
    # 下書きは、公開済みの有無によらず探す。編集ボタンを何度も押して、同じ年度の下書きを増やさないための案内に使う。
    @drafts = candidates.drafts.for_listing.order(:id).to_a
    @published = candidates.published.order(published_at: :desc, id: :desc).first
    return unless @published

    @curriculum = @published.document
    # この画面は、アプリが判定に使う要件を見せる。Catalogue を作って読み込み時の検査を通し、判定側が弾く便覧は
    # 他の画面と同じく例外にする。弾かれる便覧のまま描くと、読めない要件を読めるかのように見せてしまう。
    # 便覧が決まったときだけ作る（選んでいない・便覧が無いときに、何も無い文書で呼ばない）。
    @catalogue = GraduationAssessment::Catalogue.new(@curriculum)
  end

  # クエリの値は文字列だけを受ける。配列やハッシュ（faculty[]=x）、制御文字、壊れたエンコードは、指定されなかった扱いにする。
  def text_param(key)
    value = params[key]
    return unless value.is_a?(String)
    return unless value.valid_encoding? && value.exclude?("\0")

    value.strip.first(MAX_PARAM_LENGTH).presence
  end
end

