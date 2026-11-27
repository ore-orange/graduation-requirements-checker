# frozen_string_literal: true

require 'json'

# 卒業要件の判定を確かめるための、履修履歴を持った学生1人分。テスト専用。
# 判定のテストは「4年分の履修が入った状態」を必要とするため、fixtureではなくここで組み立てる。
class SampleStudent
  # 同じメールアドレスの学生が別の入学年度で既にいる場合。黙って作り替えると
  # テストが気づかないまま別の学生を見ることになるので止める。
  class Conflict < StandardError; end

  EMAIL = 'sample@graduation-checker.example.test'
  ADMISSION_YEAR = 2024
  CURRICULUM = 'intelligent_informatics'
  # システムテストは本物のログイン画面を通るため、決め打ちのパスワードが要る。
  PASSWORD = 'sample-student-password'
  ENROLLMENTS_PATH = 'test/fixtures/files/sample_enrollments.json'

  def self.student
    User.find_by(email: EMAIL)&.student
  end

  def self.load!
    curriculum = Curriculum.find_published(slug: CURRICULUM, admission_year: ADMISSION_YEAR).document
    enrollments = JSON.parse(Rails.root.join(ENROLLMENTS_PATH).read).fetch('enrollments')

    ActiveRecord::Base.transaction do
      courses = import_courses(curriculum.fetch('courses'))
      student = find_or_create_student
      import_enrollments(student, courses, enrollments)
      student
    end
  end

  class << self
    private

    def import_courses(entries)
      entries.to_h do |entry|
        course = Course.find_or_initialize_by(curriculum_key: entry.fetch('key'))
        course.update!(course_number: entry.fetch('number'), name: entry.fetch('name'),
                       credits: entry.fetch('credits'))
        [course.curriculum_key, course]
      end
    end

    def find_or_create_student
      # 学生が既にいてもコースは毎回ならす。カリキュラムの指し先が欠けていると画面が出せない。
      program = sample_program

      user = User.find_or_create_by!(email: EMAIL) { |new_user| new_user.password = PASSWORD }
      if user.student
        return user.student if user.student.admission_year == ADMISSION_YEAR

        raise Conflict, '同じメールアドレスの学生が別の入学年度で登録されています。'
      end

      user.create_student!(program: program, admission_year: ADMISSION_YEAR)
    end

    # 実在のマスタとは別の学部に置く。テストが実データの行を書き換えないようにするため。
    def sample_program
      faculty = Faculty.find_or_create_by!(name: 'テスト用工学部（架空データ）')
      department = faculty.departments.find_or_create_by!(name: 'テスト用知能情報学科')
      department.programs.find_or_initialize_by(name: 'テスト用知能情報コース')
                .tap { |program| program.update!(curriculum_slug: CURRICULUM) }
    end

    def import_enrollments(student, courses, entries)
      entries.each do |entry|
        enrollment = student.student_courses.find_or_initialize_by(
          course: courses.fetch(entry.fetch('course_key')),
          academic_year: entry.fetch('academic_year'),
          semester: entry.fetch('semester'),
          enrollment_status: entry.fetch('enrollment_status')
        )
        enrollment.update!(credits_earned: entry.fetch('credits_earned'),
                           approval_confirmed: entry.fetch('approval_confirmed'))
      end
    end
  end
end

