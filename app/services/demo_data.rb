# frozen_string_literal: true

require 'json'

class DemoData
  # デモ学生ごとの履修データファイル。2024年度分は元のファイル名のまま(他のテスト・既存コミットが直接参照している)。
  ENROLLMENT_FILES = {
    2024 => 'db/demo_enrollments.json',
    2025 => 'db/demo_enrollments_2025.json'
  }.freeze

  # デモの Course の種。便覧の文書ではなく、このファイルから作る(rake course_master:build で作り直す)。
  # 形は [{ "number", "name", "credits" }, ...]。
  COURSE_MASTER_FILE = 'db/course_master.json'

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
      courses = import_courses
      student = find_or_create_student(definition, curriculum)
      import_enrollments(student, courses, enrollments)
      student
    end

    # 科目は便覧の文書ではなく種ファイル(COURSE_MASTER_FILE)から作る。便覧が持つ科目は「科目番号から区分が
    # 決まらないもの」だけに絞られていて、デモ学生の履修を引き当てるには足りないため。
    # 時間割の取り込みと同じく (科目番号, 科目名) で行を探す。同じ番号で名前だけ違う行は別の行になる。
    # Course は種ファイルの行ごとに作る(便覧から予定を追加するとき、PlanCoursesController が(番号, 名前)で
    # Course を引くので、どの年度の便覧の名前でも行が要る)。
    # ただしデモの履修データ(db/demo_enrollments*.json)は course_number しか持たないので、種ファイルに同じ番号で
    # 名前の違う行が2つあると(例: 知能212 はローマ数字の全角・半角違いで2024年度と2025年度に別名で載っている)、
    # 履修をつなぐ先はどちらか1つに決めるしかない。番号で引く Hash を後勝ちで作ると並び順任せになり、
    # 学生ごとに別の Course に当たって同じ履修が2件できる。そこで、返す Hash は番号順に並んだ種ファイルの
    # 最初の行を採る(先勝ち)。
    # 単位数は最初に取り込んだ便覧の値を正とする(先着優先)。2024年度と2025年度の便覧には(科目番号, 科目名)が
    # 一致する行が57件あり、後から読む便覧の値で無条件に上書きすると、片方の便覧で単位数を「未確認」にしていても
    # もう片方の便覧が読み込まれた瞬間に値が復活してしまう。
    def import_courses
      entries = JSON.parse(Rails.root.join(COURSE_MASTER_FILE).read)
      entries.each_with_object({}) do |entry, courses|
        course = course_for(entry.fetch('number'), entry.fetch('name'))
        course.update!(credits: entry.fetch('credits')) if course.credits.nil?
        courses[course.course_number] ||= course
      end
    end

    # (科目番号, 科目名)が同じ行が複数あるとき、どれを使うかを毎回同じにする。
    # find_or_initialize_by は順序を指定しないので、DBが返す行が実行ごとに変わりうる。別の行が返ると、
    # import_enrollments が「その科目の履修はまだ無い」と見て、同じ履修をもう1件作ってしまう。
    # いちばん古い行に揃える(Curriculum.slug_for_program と同じ考え方)。
    def course_for(number, name)
      Course.where(course_number: number, name: name).order(:id).first ||
        Course.new(course_number: number, name: name)
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

    # デモ学生は便覧どおり工学部工学科(知能情報コース)の学生として作る。架空の学部・学科は作らない
    # (学部・学科のプルダウンは Faculty/Department のマスタからも作るので、架空の名前を足すと選択肢に出てしまう)。
    def create_student(user, definition)
      faculty = Faculty.find_or_create_by!(name: '工学部')
      department = faculty.departments.find_or_create_by!(name: '工学科')
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

