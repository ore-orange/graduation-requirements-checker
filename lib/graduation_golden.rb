# frozen_string_literal: true

require 'bigdecimal'
require 'json'

# 2024年度の判定結果を固定するためのケース定義と、判定結果の直列化。
# rake タスクとテストが同じ定義を呼ぶので、記録と照合の内容がずれない。
module GraduationGolden
  CURRICULUM_PATH = Rails.root.join('config/curricula/intelligent_informatics/2024.json')
  ENROLLMENTS_PATH = Rails.root.join('db/demo_enrollments.json')
  FIXTURE_PATH = Rails.root.join('test/fixtures/files/graduation_golden_2024.json')

  module_function

  def curriculum_document
    JSON.parse(CURRICULUM_PATH.read)
  end

  # ケース名 => 判定へ渡す引数。順序は固定。
  def cases(curriculum)
    courses = curriculum.fetch('courses')
    all_completed = courses.select { |course| course['selectable'] }.map { |course| completed_entry(course) }
    {
      'empty' => arguments,
      'demo' => demo_case(courses),
      'all_completed' => arguments(completed: all_completed),
      'missing_one_required' => arguments(completed: without_first_required(courses, all_completed)),
      'clean_single_path' => arguments(completed: clean_single_path(curriculum, all_completed)),
      'natural_cap_only' => arguments(completed: natural_cap_only(courses))
    }
  end

  def record(curriculum)
    cases(curriculum).transform_values do |arguments|
      result = GraduationAssessment.new(curriculum: curriculum).call(**arguments)
      { 'actual' => snapshot(result.actual), 'projected' => snapshot(result.projected) }
    end
  end

  # 比較を安定させるため、キー順・配列順を固定し、単位は文字列にする。
  def snapshot(snapshot)
    {
      'status' => snapshot.status.to_s,
      'counted_credits' => credits(snapshot.counted_credits),
      'review_notes' => snapshot.review_notes.sort,
      'checks' => snapshot.checks.sort_by(&:id).map { |check| check_hash(check) }
    }
  end

  def json(curriculum)
    "#{JSON.pretty_generate(sort_keys(record(curriculum)))}\n"
  end

  def arguments(completed: [], registered: [], unresolved: [])
    { completed: completed, registered: registered, planned: [], unresolved: unresolved }
  end

  def completed_entry(course, credits: course['credits'], approved: nil)
    { key: course['key'], credits: credits, approved: approved, name: course['name'] }
  end

  def demo_case(courses)
    by_key = courses.index_by { |course| course['key'] }
    groups = { completed: [], registered: [], unresolved: [] }
    JSON.parse(ENROLLMENTS_PATH.read).fetch('enrollments').each do |enrollment|
      course = by_key.fetch(enrollment['course_key'])
      status = enrollment['enrollment_status']
      case status
      when 'completed'
        groups[:completed] << completed_entry(course, credits: enrollment['credits_earned'],
                                                      approved: enrollment['approval_confirmed'])
      when 'registered', 'in_progress'
        groups[:registered] << completed_entry(course, approved: enrollment['approval_confirmed'])
      when 'unknown'
        groups[:unresolved] << completed_entry(course, credits: nil, approved: enrollment['approval_confirmed'])
      end
    end
    arguments(**groups)
  end

  def without_first_required(courses, entries)
    key = courses.select { |course| course['required'] }.pluck('key').min
    raise 'required の科目が科目表にない' if key.nil?

    entries.reject { |entry| entry[:key] == key }
  end

  # 微分積分学は系列の一方、物理学は代替の一方だけで、単位数が不明な科目も含まない状態。
  def clean_single_path(curriculum, entries)
    requirements = curriculum.fetch('requirements')
    dropped = curriculum.fetch('courses').select do |course|
      roles = course.fetch('roles', [])
      course['credits'].nil? || roles.intersect?(requirements.fetch('calculus_paths').fetch(1)) ||
        roles.include?(requirements.fetch('physics_roles').fetch(1))
    end.pluck('key')
    entries.reject { |entry| dropped.include?(entry[:key]) }
  end

  # 自然系の算入上限だけを確かめるため、キー順で先頭3科目以外は何も入れない。
  def natural_cap_only(courses)
    courses.select { |course| course['category'] == 'natural' }.sort_by { |course| course['key'] }.first(3)
           .map { |course| completed_entry(course) }
  end

  def check_hash(check)
    {
      'id' => check.id,
      'status' => check.status.to_s,
      'counted_credits' => credits(check.counted_credits),
      'required_credits' => credits(check.required_credits),
      'missing_courses' => check.missing_courses.sort
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
end

