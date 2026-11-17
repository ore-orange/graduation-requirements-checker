# frozen_string_literal: true

# 卒業要件の確認画面で選ばれた対象(学部・学科・コース・入学年度)と、その組み合わせで引ける便覧。
#
# 画面の選択はクエリ(GET)で持つので、値は信用せずに受ける。文字列以外(配列・ハッシュ)、制御文字、壊れた
# エンコードは、指定されなかった扱いにする。変な値(無い学部・数字でない年度)は、何も見つからないだけで、
# 例外にも別の便覧にもならない。
#
# Curriculum#department_name は学科名とコース名を1つの文字列で持つ(例: "工学科 知能情報コース")。
# 画面は学科とコースを別の欄で扱うので、結ぶ・分けるのはこのクラスの仕事にする。
class CurriculumSelection
  KEYS = %i[faculty department course admission_year].freeze
  # 年度は Curriculum の検証(1..9999)と同じ範囲だけを受ける。桁あふれの値をそのまま SQL に渡さないため。
  YEAR_RANGE = 1..9999
  # 受ける文字列の長さの上限。画面に「ありません」と出すときに、巨大な値をそのまま返さないため。
  MAX_LENGTH = 100

  attr_reader :faculty, :department, :course, :admission_year

  # 便覧(保存前・削除後の行でもよい)が指す対象。学科コース名は Program の組で学科とコースに分ける。
  def self.for(curriculum, choices: CurriculumChoices.new)
    department, course = Program.department_and_course_for(curriculum.department_name)
    new({ faculty: curriculum.faculty_name, department: department, course: course,
          admission_year: curriculum.admission_year }, choices: choices)
  end

  def initialize(params, choices: CurriculumChoices.new)
    @choices = choices
    @faculty, @department, @course, @admission_year = KEYS.map { |key| text(params[key]) }
  end

  # 1つでも指定されているか。揃っていないときに、足りないことを伝えるために見る。
  def given? = values.any?(&:present?)

  # 学部・学科・年度が揃っているか。ここまで揃っていれば、コースの有無によらず画面を開ける
  # (その画面でコースまで要るかは complete? が決める)。
  def named? = [faculty, department, admission_year].all?(&:present?)

  # 学部・学科・年度は常に必須。コースは、選んだ学科にコースの選択肢があるときだけ必須にする
  # (コースの無い学科の便覧は、学科名だけで引ける)。
  def complete? = named? && (course_required? ? course.present? : true)

  # Curriculum#department_name と同じ形に結んだ、学科コース名
  def department_name = [department, course].compact_blank.join(' ')

  # 画面のパス(requirements_path)に渡す、指定のあった値だけ
  def to_params = KEYS.zip(values).to_h.compact_blank

  # 下書きは、公開済みの有無によらず探す。編集ボタンを何度も押して、同じ年度の下書きを増やさないための案内に使う。
  # 行の見た目は同じになりやすい(年度・コース名・ファイル名)ので、更新の新しい順に並べ、行ごとに更新日時を出す
  # (古い版を選ばせない)。同じ時刻なら、あとから作った方を先にする。
  def drafts = @drafts ||= candidates.drafts.for_listing.order(updated_at: :desc, id: :desc).to_a

  def published = @published ||= candidates.published.order(published_at: :desc, id: :desc).first

  private

  attr_reader :choices

  def values = [faculty, department, course, admission_year]

  # 3つ揃っていなければ便覧は引かない(最初の画面は、選択だけを出す)
  def candidates
    return Curriculum.none unless complete? && year

    Curriculum.where(faculty_name: faculty, department_name: department_name, admission_year: year)
  end

  def year
    parsed = Integer(admission_year.to_s, 10, exception: false)
    parsed if parsed && YEAR_RANGE.cover?(parsed)
  end

  def course_required?
    choices.courses_for(department).any? && !department_only_curriculum?
  end

  # ただし、学科名だけで登録されている便覧(マスタにコースを足す前に作ったものなど)があるときは求めない。
  # 求めてしまうと、どのコースを選んでも結んだ名前が一致せず、その便覧に二度とたどり着けなくなる。
  def department_only_curriculum?
    department.present? && Curriculum.exists?(faculty_name: faculty, department_name: department)
  end

  def text(value)
    value = value.to_s if value.is_a?(Integer)
    return unless value.is_a?(String)
    return unless value.valid_encoding? && value.exclude?("\0")

    value.strip.first(MAX_LENGTH).presence
  end
end

