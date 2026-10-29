# frozen_string_literal: true

require 'json'

class DemoData
  def self.load!
    raise DemoAccount::Unavailable, 'デモデータは開発・テスト環境でのみ投入できます。' unless DemoAccount.enabled?

    curriculum = Curriculum.published.find_by!(slug: DemoAccount::DEPARTMENT,
                                               admission_year: DemoAccount::ADMISSION_YEAR)
    enrollments = JSON.parse(Rails.root.join('db/demo_enrollments.json').read).fetch('enrollments')

    ActiveRecord::Base.transaction do
      courses = import_courses(curriculum.document.fetch('courses'))
      student = find_or_create_student(curriculum)
      import_enrollments(student, courses, enrollments)
      student
    end
  end

  class << self
    private

    # 科目番号の無い科目は、履修や予定から引き当てる手がかりが無いので作らない。
    # 時間割の取り込みと同じく (科目番号, 科目名) で行を探す。同じ番号で名前だけ違う行は別の行になる。
    def import_courses(entries)
      entries.select { |entry| entry['number'].present? }.to_h do |entry|
        course = Course.find_or_initialize_by(course_number: entry.fetch('number'), name: entry.fetch('name'))
        course.update!(credits: entry.fetch('credits'))
        [course.course_number, course]
      end
    end

    def find_or_create_student(curriculum)
      user = User.find_or_create_by!(email: DemoAccount::EMAIL)
      student = user.student || create_student(user)
      unless student.admission_year == DemoAccount::ADMISSION_YEAR
        raise DemoAccount::Unavailable, 'デモ用メールアドレスの既存データは2024年度入学ではないため、上書きできません。'
      end

      student.update!(curriculum: curriculum) unless student.curriculum == curriculum
      student
    end

    def create_student(user)
      faculty = Faculty.find_or_create_by!(name: 'デモ用工学部（架空データ）')
      department = faculty.departments.find_or_create_by!(name: '知能情報工学（デモ）')
      user.create_student!(department: department, admission_year: DemoAccount::ADMISSION_YEAR)
    end

    def import_enrollments(student, courses, entries)
      entries.each do |entry|
        enrollment = student.student_courses.find_or_initialize_by(
          course: courses.fetch(entry.fetch('course_number')),
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

