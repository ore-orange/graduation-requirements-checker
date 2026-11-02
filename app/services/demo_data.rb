# frozen_string_literal: true

require 'json'

class DemoData
  # デモ学生ごとの履修データファイル。2024年度分は元のファイル名のまま(他のテスト・既存コミットが直接参照している)。
  ENROLLMENT_FILES = {
    2024 => 'db/demo_enrollments.json',
    2025 => 'db/demo_enrollments_2025.json'
  }.freeze

  # 設定されているデモ学生のうち、便覧が公開済みのものだけを投入する。戻り値は実際に投入した学生の配列
  # (DemoAccount.students と要素数が一致しないことがある)。全員まとめて1つのトランザクションにし、
  # どれか1人でも既存データと衝突すれば全体を巻き戻す(一部だけ作られた中途半端な状態を残さない)。
  def self.load!
    raise DemoAccount::Unavailable, 'デモデータは開発・テスト環境でのみ投入できます。' unless DemoAccount.enabled?

    ActiveRecord::Base.transaction do
      DemoAccount.students.filter_map { |definition| load_student(definition) }
    end
  end

  class << self
    private

    # 便覧がまだ公開されていない入学年度(取り込み待ちの年度)は、デモ学生を作らず黙ってスキップする。
    # 例外にすると、1年度分の便覧がまだ無いだけで bin/rails db:seed 全体が止まってしまう。
    def load_student(definition)
      curriculum = definition.curriculum
      return unless curriculum

      enrollments = JSON.parse(Rails.root.join(ENROLLMENT_FILES.fetch(definition.admission_year)).read)
                        .fetch('enrollments')
      courses = import_courses(curriculum.document.fetch('courses'))
      student = find_or_create_student(definition, curriculum)
      import_enrollments(student, courses, enrollments)
      student
    end

    # 科目番号の無い科目は、履修や予定から引き当てる手がかりが無いので作らない。
    # 時間割の取り込みと同じく (科目番号, 科目名) で行を探す。同じ番号で名前だけ違う行は別の行になる。
    def import_courses(entries)
      entries.select { |entry| entry['number'].present? }.to_h do |entry|
        course = Course.find_or_initialize_by(course_number: entry.fetch('number'), name: entry.fetch('name'))
        course.update!(credits: entry.fetch('credits'))
        [course.course_number, course]
      end
    end

    def find_or_create_student(definition, curriculum)
      user = User.find_or_create_by!(email: definition.email)
      student = user.student || create_student(user, definition)
      unless student.admission_year == definition.admission_year
        raise DemoAccount::Unavailable,
              "デモ用メールアドレス(#{definition.email})の既存データは" \
              "#{definition.admission_year}年度入学ではないため、上書きできません。"
      end

      student.update!(curriculum: curriculum) unless student.curriculum == curriculum
      student
    end

    def create_student(user, definition)
      faculty = Faculty.find_or_create_by!(name: 'デモ用工学部（架空データ）')
      department = faculty.departments.find_or_create_by!(name: '知能情報工学（デモ）')
      user.create_student!(department: department, admission_year: definition.admission_year)
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

