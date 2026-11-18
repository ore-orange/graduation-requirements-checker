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
  # 科目の種。便覧の文書ではなくこのファイルから作る(rake course_master:build で作り直す)。
  # 便覧が持つ科目は「科目番号から区分が決まらないもの」だけに絞られていて、履修を引き当てるには足りない。
  # 形は [{ "number", "name", "credits" }, ...]。
  COURSE_MASTER_PATH = 'db/course_master.json'

  def self.student
    User.find_by(email: EMAIL)&.student
  end

  def self.load!
    enrollments = JSON.parse(Rails.root.join(ENROLLMENTS_PATH).read).fetch('enrollments')

    ActiveRecord::Base.transaction do
      courses = import_courses
      student = find_or_create_student
      import_enrollments(student, courses, enrollments)
      student
    end
  end

  class << self
    private

    # 時間割の取り込みと同じく (科目番号, 科目名) で行を探す。同じ番号で名前だけ違う行は別の行になる。
    # 履修データ(sample_enrollments.json)は course_number しか持たないので、同じ番号で名前の違う行が
    # 2つあるときに履修をつなぐ先を決めきれない。番号で引く Hash は、番号順に並んだ種ファイルの
    # 最初の行を採る(先勝ち)。後勝ちにすると並び順任せになり、同じ履修が2件できることがある。
    # 単位数も先着優先。後から読む行で無条件に上書きすると、「未確認」にしている値が復活してしまう。
    def import_courses
      entries = JSON.parse(Rails.root.join(COURSE_MASTER_PATH).read)
      entries.each_with_object({}) do |entry, courses|
        course = course_for(entry.fetch('number'), entry.fetch('name'))
        course.update!(credits: entry.fetch('credits')) if course.credits.nil?
        courses[course.course_number] ||= course
      end
    end

    # (科目番号, 科目名)が同じ行が複数あるとき、どれを使うかを毎回同じにする。
    # find_or_initialize_by は順序を指定しないので、DBが返す行が実行ごとに変わりうる。
    def course_for(number, name)
      Course.where(course_number: number, name: name).order(:id).first ||
        Course.create!(course_number: number, name: name)
    end

    def find_or_create_student
      # 学生が既にいてもコースは毎回ならす。便覧の指し先が欠けていると画面が出せない。
      program = sample_program

      user = User.find_or_create_by!(email: EMAIL) { |new_user| new_user.password = PASSWORD }
      if user.student
        return user.student if user.student.admission_year == ADMISSION_YEAR

        raise Conflict, '同じメールアドレスの学生が別の入学年度で登録されています。'
      end

      # 便覧(Curriculum の行)は Student が識別名と入学年度から引き当てる。
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

