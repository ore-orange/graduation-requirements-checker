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
                   course: text_param(:course), admission_year: text_param(:admission_year) }
    @drafts = []
    return unless selection_complete?

    resolve_selection
  end

  private

  # 学部・学科・年度は常に必須。コースは、選んだ学科にコースの選択肢があるときだけ必須にする
  # (コースの無い学科の便覧は、学科名だけで引ける)。
  def selection_complete?
    required = [@selection[:faculty], @selection[:department], @selection[:admission_year]]
    required.all?(&:present?) && (course_required? ? @selection[:course].present? : true)
  end

  # ただし、学科名だけで登録されている便覧(マスタにコースを足す前に作ったものなど)があるときは求めない。
  # 求めてしまうと、どのコースを選んでも結んだ名前が一致せず、その便覧に二度とたどり着けなくなる。
  def course_required?
    @course_options.fetch(@selection[:department], []).any? && !department_only_curriculum?
  end

  def department_only_curriculum?
    @selection[:department].present? &&
      Curriculum.exists?(faculty_name: @selection[:faculty], department_name: @selection[:department])
  end

  # 1つでも指定されているか。揃っていないときに、足りないことを伝えるために見る。
  def selection_given? = @selection.values.any?(&:present?)

  # 選択肢は、Faculty/Department/Programのマスタから作る（便覧の有無を問わない。まだ便覧の無い組み合わせも選べる）。
  # 入学年度だけは、実在する便覧（公開済みも下書きも）の実データから作る（下書きだけの年度も選べるように）。
  # 既存の便覧がマスタに無い学部・学科コース名を持っていることもある(マスタに追加する前の下書きなど)。
  # そういう組み合わせも選べるよう、マスタの一覧に足す(コースに割れる名前は、Programの組で判定済みなので足さない)。
  def load_options
    @faculty_options = Faculty.order(:name).pluck(:name)
    @department_options = Department.joins(:faculty).order('faculties.name', :name)
                                    .pluck('faculties.name', :name).group_by(&:first)
                                    .transform_values { |pairs| pairs.map(&:last) }
    @course_options = Program.joins(:department).order('departments.name', :name)
                             .pluck('departments.name', :name).group_by(&:first)
                             .transform_values { |pairs| pairs.map(&:last) }
    # where.not に2列を渡すと「2列とも空、ではない」になり、片方だけ空の行が残ってしまう。1列ずつ除く。
    names = Curriculum.where.not(faculty_name: [nil, '']).where.not(department_name: [nil, ''])
    @year_options = names.distinct.order(admission_year: :desc).pluck(:admission_year)
    add_legacy_department_options(names)
  end

  def add_legacy_department_options(names)
    names.distinct.pluck(:faculty_name, :department_name).each do |faculty_name, department_name|
      department, course = Program.department_and_course_for(department_name)
      next if course # Programの組で判定済み(マスタの学科・コースに載っている)

      known = (@department_options[faculty_name] ||= [])
      known << department unless known.include?(department)
    end
  end

  # 選んだ組み合わせの便覧を探す。変な値（無い学部・数字でない年度）は、何も見つからないだけで、例外にも別の便覧にもならない。
  # 学科名とコース名は、Curriculum#department_name が1つの文字列で持つのと同じ形に結んで照合する。
  def resolve_selection
    year = Integer(@selection[:admission_year], 10, exception: false)
    return unless year && YEAR_RANGE.cover?(year)

    department_name = [@selection[:department], @selection[:course]].compact_blank.join(' ')
    candidates = Curriculum.where(faculty_name: @selection[:faculty], department_name: department_name,
                                  admission_year: year)
    # 下書きは、公開済みの有無によらず探す。編集ボタンを何度も押して、同じ年度の下書きを増やさないための案内に使う。
    # 行の見た目は同じになりやすい(年度・コース名・ファイル名)ので、更新の新しい順に並べ、行ごとに更新日時を出す(古い版を選ばせない)。
    # 同じ時刻なら、あとから作った方を先にする。
    @drafts = candidates.drafts.for_listing.order(updated_at: :desc, id: :desc).to_a
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

