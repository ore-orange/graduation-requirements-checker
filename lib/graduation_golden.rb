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
      'both_calculus_paths' => arguments(completed: with_courses(all_completed, courses, calculus_keys(curriculum))),
      'natural_over_cap' => arguments(completed: with_courses(all_completed, courses, natural_keys(courses).first(3)))
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

  def calculus_keys(curriculum)
    curriculum.fetch('requirements').fetch('calculus_paths').flatten
  end

  def natural_keys(courses)
    courses.select { |course| course['category'] == 'natural' }.pluck('key')
  end

  # 指定のキーの科目を、記録済みでなければ修得済みとして加える。
  def with_courses(entries, courses, keys)
    by_key = courses.index_by { |course| course['key'] }
    present = entries.pluck(:key)
    entries + (keys - present).map { |key| completed_entry(by_key.fetch(key)) }
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

