# frozen_string_literal: true

require 'bigdecimal'
require 'json'

# 2024年度の便覧で、いまの判定結果を記録しておくためのケースと直列化。
# 判定の作りを置き換えるときに、結果が1件も変わっていないことをテストで照合する。
# rake タスク(書き出し)とテスト(照合)が同じ定義を呼ぶので、記録と照合の中身はずれない。
#
# ケースは科目表の欄(区分・役割・提供コース・言語)だけから組み立てる。要件の書き方(どこに必要単位を書くか)には
# 依存させない。要件の形式を変えても、同じケースで同じ結果になることを確かめるため。
module GraduationGolden
  CURRICULUM_PATH = Rails.root.join('config/curricula/intelligent_informatics/2024.json')
  ENROLLMENTS_PATH = Rails.root.join('test/fixtures/files/sample_enrollments.json')
  FIXTURE_PATH = Rails.root.join('test/fixtures/files/graduation_golden_2024.json')

  module_function

  def curriculum_document
    JSON.parse(CURRICULUM_PATH.read)
  end

  # ケース名 => 判定へ渡す引数。
  def cases(document)
    Cases.new(document.fetch('courses')).to_h
  end

  # 予定を数えても結果が変わらないケースは、projected にこの印だけを置く(同じ中身を2回書かない)。
  SAME_AS_ACTUAL = 'actual と同じ'
  # そのまま全単位を算入した科目の理由。記録には、これ以外の科目だけを書く。
  PLAIN_REASON = '卒業単位に算入'

  def record(document)
    cases(document).transform_values do |arguments|
      result = GraduationAssessment.new(curriculum: document).call(**arguments)
      actual = snapshot(result.actual)
      projected = snapshot(result.projected)
      { 'actual' => actual, 'projected' => projected == actual ? SAME_AS_ACTUAL : projected }
    end
  end

  def json(document)
    "#{Format.call(sort_keys(record(document)))}\n"
  end

  # 画面に出る文言(見出し・説明・注記)と、科目ごとの算入まで記録する。数字が同じでも文言が変われば気づけるように。
  # 科目は、全単位をそのまま算入したもの以外(一部だけ算入・算入しない・要確認)だけを書き、全体の数を添える。
  # 比較を安定させるため、配列の並びを固定し、単位は文字列にする。
  def snapshot(snapshot)
    results = snapshot.course_results.sort_by { |result| [result.key.to_s, result.name.to_s] }
                      .map { |result| course_result_hash(result) }
    {
      'status' => snapshot.status.to_s,
      'counted_credits' => credits(snapshot.counted_credits),
      'review_notes' => snapshot.review_notes.sort,
      'checks' => snapshot.checks.sort_by(&:id).map { |check| check_hash(check) },
      'course_count' => results.size,
      'course_exceptions' => results.reject { |result| plain?(result) }
    }
  end

  def plain?(result)
    result['reason'] == PLAIN_REASON && result['counted_credits'] == result['credits']
  end

  def check_hash(check)
    {
      'id' => check.id,
      'label' => check.label,
      'status' => check.status.to_s,
      'counted_credits' => credits(check.counted_credits),
      'required_credits' => credits(check.required_credits),
      'missing_courses' => check.missing_courses.sort,
      'source' => check.source,
      'detail' => check.detail
    }
  end

  def course_result_hash(result)
    {
      'key' => result.key,
      'name' => result.name,
      'credits' => credits(result.credits),
      'counted_credits' => credits(result.counted_credits),
      'reason' => result.reason
    }
  end

  def credits(value)
    BigDecimal(value.to_s).to_s('F') unless value.nil?
  end

  def sort_keys(value)
    case value
    when Hash then value.sort.to_h { |key, child| [key, sort_keys(child)] }
    when Array then value.map { |child| sort_keys(child) }
    else value
    end
  end

  # 記録の書き方。差分を読みやすくするため、チェック1件・科目1件を1行に書く。
  # 中に Hash や Hash の配列を持たない Hash(葉)は1行、それ以外は1要素ずつ改行する。
  module Format
    module_function

    def call(value, indent = 0)
      return JSON.generate(value) if one_line?(value)

      open, close = value.is_a?(Hash) ? %w[{ }] : %w[[ ]]
      "#{open}\n#{items(value, indent).join(",\n")}\n#{'  ' * indent}#{close}"
    end

    def items(value, indent)
      inner = '  ' * (indent + 1)
      return value.map { |child| inner + call(child, indent + 1) } if value.is_a?(Array)

      value.map { |key, child| "#{inner}#{JSON.generate(key)}: #{call(child, indent + 1)}" }
    end

    def one_line?(value)
      case value
      when Hash then value.values.none? { |child| child.is_a?(Hash) || (child.is_a?(Array) && child.any?(Hash)) }
      when Array then value.empty?
      else true
      end
    end
  end

  # 記録するケースの組み立て。科目はキー順に選び、毎回同じ科目になるようにする。
  class Cases
    def initialize(courses)
      @courses = courses.sort_by { |course| course.fetch('key') }
      @by_key = @courses.index_by { |course| course.fetch('key') }
    end

    def to_h
      completed = overall_cases.merge(path_cases, credit_cases)
                               .transform_values { |courses| arguments(completed: entries(courses)) }
      { 'empty' => arguments, 'sample' => sample }.merge(
        completed,
        'registered_and_planned' => registered_and_planned,
        'conflicting_records' => conflicting_records,
        'unknown_and_unresolved' => unknown_and_unresolved
      )
    end

    private

    # 以下の3つは、修得済みの科目だけを渡すケース(ケース名 => 科目)。
    def overall_cases
      {
        'all_completed' => selectable,
        'missing_one_required' => selectable - [required.first],
        'clean_single_path' => clean_single_path,
        'excluded_course' => in_category('excluded'),
        'unverified_credits' => @courses.select { |course| course['credits'].nil? }
      }
    end

    # 系列・代替・上限
    def path_cases
      {
        'calculus_mixed_paths' => with_roles(%w[calculus_st_1 calculus_intro_1]),
        'physics_both_alternatives' => with_roles(%w[physics_1 physics_intro_1]),
        'natural_over_cap' => in_category('natural').first(3)
      }
    end

    # 外国語の言語ごとの集計と、工学融合の提供コースごとの集計
    def credit_cases
      {
        'english_plus_one_language' => english(8) + language('german', 4),
        'english_plus_two_languages' => english(8) + language('latin', 2) + language('russian', 2),
        'fusion_one_provider' => fusion('mechanical', 4),
        'fusion_split_providers' => fusion('mechanical', 2) + fusion('civil', 2),
        'fusion_own_course' => fusion('intelligent_informatics', 4)
      }
    end

    def arguments(completed: [], registered: [], planned: [], unresolved: [])
      { completed: completed, registered: registered, planned: planned, unresolved: unresolved }
    end

    def entry(course, credits: course['credits'], approved: nil)
      { key: course.fetch('key'), credits: credits, approved: approved, name: course.fetch('name') }
    end

    def entries(courses) = courses.map { |course| entry(course) }
    def selectable = @courses.select { |course| course['selectable'] }
    def required = @courses.select { |course| course['required'] }
    def in_category(category) = @courses.select { |course| course['category'] == category }
    def with_roles(roles) = @courses.select { |course| course.fetch('roles', []).intersect?(roles) }

    # 微分積分学はSTの系列、物理学は物理学Ⅰだけを取り、単位数の分からない科目も含めない、迷いのない状態。
    def clean_single_path
      other_paths = %w[calculus_intro_1 calculus_intro_2 physics_intro_1]
      selectable.reject do |course|
        course['credits'].nil? || course.fetch('roles', []).intersect?(other_paths)
      end
    end

    # 区分の先頭から、合計がちょうど credits 単位になるまで選ぶ。
    def take_credits(courses, credits)
      total = 0
      known = courses.reject { |course| course['credits'].nil? }
      picked = known.take_while { |course| (total += course['credits']) <= credits }
      raise "#{credits}単位ちょうどに選べない" unless picked.sum { |course| course['credits'] } == credits

      picked
    end

    def english(credits) = take_credits(in_category('english'), credits)

    def language(name, credits)
      take_credits(in_category('foreign_language').select { |course| course['language'] == name }, credits)
    end

    def fusion(provider, credits)
      take_credits(in_category('fusion').select { |course| course['provider'] == provider }, credits)
    end

    def sample
      groups = { completed: [], registered: [], unresolved: [] }
      JSON.parse(ENROLLMENTS_PATH.read).fetch('enrollments').each do |enrollment|
        course = @by_key.fetch(enrollment.fetch('course_key'))
        approved = enrollment['approval_confirmed']
        case enrollment.fetch('enrollment_status')
        when 'completed'
          groups[:completed] << entry(course, credits: enrollment['credits_earned'], approved: approved)
        when 'registered', 'in_progress' then groups[:registered] << entry(course, approved: approved)
        when 'unknown' then groups[:unresolved] << entry(course, credits: nil, approved: approved)
        end
      end
      arguments(**groups)
    end

    # 修得済みの科目を予定にも重ねたもの(増えない)と、まだ取っていない科目の履修中・予定。
    def registered_and_planned
      completed = required.first(5)
      arguments(completed: entries(completed), registered: entries(required[5, 3]),
                planned: entries(completed.first(2) + required[8, 3]))
    end

    # 同じ科目の修得記録が2件あり、単位数が食い違う。どちらかを勝手に選ばない。
    def conflicting_records
      course = required.first
      arguments(completed: [entry(course), entry(course, credits: course['credits'] + 1)])
    end

    # 科目表に無いキーと、履修状態の分からない記録。
    def unknown_and_unresolved
      unknown = { key: 'not_in_handbook', credits: 2, approved: nil, name: '便覧に無い科目' }
      unresolved = [entry(required.first, credits: nil), entry(in_category('excluded').first, credits: nil)]
      arguments(completed: [unknown], unresolved: unresolved)
    end
  end
end

