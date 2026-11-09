# frozen_string_literal: true

# 学生1人分の履修データと卒業要件を読み込み、各画面に渡す。
# 認証が入るまでは固定のデモ学生をローカル環境でのみ扱う。
module StudentWorkspace
  extend ActiveSupport::Concern

  CURRENT_STATUSES = %w[registered in_progress].freeze
  # 学期は { grade: 2, semester: '後期' } で表し、1年前期〜4年後期を時系列順に並べる。
  SEMESTERS = %w[前期 後期].freeze
  TERMS = (1..4).flat_map { |grade| SEMESTERS.map { |semester| { grade: grade, semester: semester } } }.freeze
  TERM_PARAM = /\A(?<grade>[1-4])-(?<semester>前期|後期)\z/

  included do
    before_action :require_local_demo
    before_action :load_workspace

    rescue_from DemoAccount::Unavailable, with: :show_setup
  end

  private

  def require_local_demo
    head :not_found unless local_demo_access?
  end

  # 全画面で必要になる最小限。履修履歴は使う画面だけが enrollments で読む。
  def load_workspace
    @student = DemoAccount.student
    # @curriculum は便覧の文書（Hash）。読み手は fetch で引くので、レコードは渡さない。
    @curriculum = published_curriculum(@student).document
    # 履修・予定の Course は、科目番号で便覧の科目に当たる。番号の無い科目は当たりようがないので入れない。
    @courses_by_number = @curriculum.fetch('courses').select { |course| course['number'].present? }
                                    .index_by { |course| course.fetch('number') }
  end

  # 学生が持つ便覧。無い、または公開済みでなければ、判定せずに初期設定の案内を出す。
  # 公開前の便覧は作業中の文書なので、誰の判定にも使わない。
  def published_curriculum(student)
    curriculum = student.curriculum
    raise DemoAccount::Unavailable, '学生に便覧が設定されていません。bin/rails db:seed を実行してください。' unless curriculum
    return curriculum if curriculum.published?

    raise DemoAccount::Unavailable, '公開済みの便覧がありません。bin/rails db:seed を実行してください。'
  end

  def enrollments
    @enrollments ||= @student.student_courses.includes(:course).order(:academic_year, :id).to_a
  end

  def load_plans
    @plans = @student.planned_courses.includes(:course).order(:id).to_a
  end

  def load_history
    enrollments
    @completed = @enrollments.select { |enrollment| enrollment.enrollment_status == 'completed' }
    @current = @enrollments.select { |enrollment| CURRENT_STATUSES.include?(enrollment.enrollment_status) }
    @other_enrollments = @enrollments - @completed - @current
  end

  # 判定へ渡す履修・予定は、Course の科目番号を key にした形で組む。便覧の科目に当てるのは最後。
  def assess
    unknown = @other_enrollments.select { |enrollment| enrollment.enrollment_status == 'unknown' }
    groups = { completed: @completed.map(&:assessment_entry), registered: @current.map(&:assessment_entry),
               planned: @plans.map { |plan| planned_entry(plan) }, unresolved: unknown.map(&:assessment_entry) }
    GraduationAssessment.new(curriculum: @curriculum).call(**catalogue_entries(groups))
  end

  def planned_entry(plan)
    course = @courses_by_number[plan.course.course_number]
    credits = course ? course.fetch('credits') : plan.course.credits
    # 指導教員の承認が要る科目か自体は便覧(course)が決める。得たかどうかは学生側の事実なので、答えていなければ
    # nil のまま渡す（黙って false にすると「承認なし」と答えたことになり、黙って true にすると未回答でも通る）。
    # number は key と別に持つ(catalogue_entries が key を振り替えても、番号パターンの推定に使えるように)。
    { key: plan.course.course_number, number: plan.course.course_number, credits: credits,
      approved: plan.approval_confirmed, name: plan.course.name }
  end

  # 科目番号が便覧の科目に当たれば、その科目の key で判定に渡す。同じ番号の Course が複数あっても、履修・予定は
  # それぞれ1行を指し、その番号は便覧の同じ1科目に当たる。同じ科目の複数記録は EntryNormalizer が1つにまとめ、
  # 単位数や承認が食い違うときだけ要確認にする。
  #
  # 当たらない科目には "unmatched:" で始まる key を振る(番号の綴りがたまたま別の科目の key に一致しても
  # 取り違えないため)。番号があればその番号で束ねる。束ねないと、同じ科目の2つの記録(落ちた回と通った回)が
  # 別々の記録として扱われ、単位数の食い違いを見る上の仕組みが働かないまま、片方の単位だけが数えられてしまう。
  # 番号の無い科目は束ねようがないので、1件ずつ別の key にする(別々の科目が1つにまとまって通知が落ちないように)。
  def catalogue_entries(groups)
    unmatched = 0
    groups.transform_values do |entries|
      entries.map do |entry|
        course = @courses_by_number[entry[:key]]
        next entry.merge(key: course.fetch('key')) if course

        number = entry[:number].presence
        entry.merge(key: "unmatched:#{number || (unmatched += 1)}")
      end
    end
  end

  # URL の "2-後期" を学期にする。読めない値は nil。
  def parse_term(value)
    match = TERM_PARAM.match(value.to_s)
    { grade: match[:grade].to_i, semester: match[:semester] } if match
  end

  # 年度は4月始まりで、4〜9月を前期、10〜3月を後期とする。在学期間の外なら端の学期にする。
  def current_term(date = Date.current)
    academic_year = date.month >= 4 ? date.year : date.year - 1
    semester_index = date.month.between?(4, 9) ? 0 : 1
    TERMS[(((academic_year - @student.admission_year) * SEMESTERS.size) + semester_index).clamp(0, TERMS.size - 1)]
  end

  # 履修履歴・予定の年度と学期から学期を求める。入学前・5年目以降は1年・4年に寄せる。学期が不明なら nil。
  def term_of(record)
    return unless SEMESTERS.include?(record.semester)

    { grade: (record.academic_year - @student.admission_year + 1).clamp(1, 4), semester: record.semester }
  end

  def term_year(term) = @student.admission_year + term[:grade] - 1

  # 予定を追加できるのは今の学期とそれ以降。
  def term_open?(term) = TERMS.index(term) >= TERMS.index(current_term)

  # 例外のメッセージは、何が足りないかを指す固定の文言なので、そのまま画面に出す。
  def show_setup(error)
    @setup_message = error.message
    render 'shared/setup', status: :service_unavailable
  end
end

