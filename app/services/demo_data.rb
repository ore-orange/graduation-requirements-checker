# frozen_string_literal: true

require 'json'

class DemoData
  def self.load!
    raise DemoAccount::Unavailable, 'デモデータは開発・テスト環境でのみ投入できます。' unless DemoAccount.enabled?

    curriculum = CurriculumRepository.find(curriculum: DemoAccount::DEPARTMENT,
                                           admission_year: DemoAccount::ADMISSION_YEAR)
    enrollments = JSON.parse(Rails.root.join('db/demo_enrollments.json').read).fetch('enrollments')

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
      program = demo_program

      # デモはログイン画面のボタンから入る。パスワードでは入らせないので、誰も知らない値にしておく。
      user = User.find_or_create_by!(email: DemoAccount::EMAIL) do |new_user|
        new_user.password = SecureRandom.hex(32)
      end
      if user.student
        return user.student if user.student.admission_year == DemoAccount::ADMISSION_YEAR

        raise DemoAccount::Unavailable, 'デモ用メールアドレスの既存データは2024年度入学ではないため、上書きできません。'
      end

      user.create_student!(program: program, admission_year: DemoAccount::ADMISSION_YEAR)
    end

    # コース名は学科名と同じにしている。学科からコースへ移すマイグレーションが
    # 学科名をそのまま引き写すため、名前を変えると同じ学科にコースが2つできる。
    def demo_program
      faculty = Faculty.find_or_create_by!(name: 'デモ用工学部（架空データ）')
      department = faculty.departments.find_or_create_by!(name: '知能情報工学（デモ）')
      department.programs.find_or_initialize_by(name: '知能情報工学（デモ）')
                .tap { |program| program.update!(curriculum_slug: DemoAccount::DEPARTMENT) }
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

