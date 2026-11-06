# frozen_string_literal: true

# 学科の中の「コース」の最小セット。何度流しても増えない。
#
# AcademicOrganizations と同じく、確からしい根拠(既存の Curriculum の実データ)があるものだけを書く。
# 工学部工学科には他にもコースがあるはずだが、他学部・他学科と同じく確かめていないので作らない
# (コースの無い学科として扱う。取り込みフォームの「その他」から登録できる)。
module Programs
  COURSES = {
    '工学部' => {
      '工学科' => ['知能情報コース']
    }
  }.freeze

  def self.load!
    COURSES.each do |faculty_name, departments|
      departments.each do |department_name, course_names|
        department = Faculty.find_by!(name: faculty_name).departments.find_by!(name: department_name)
        course_names.each { |name| department.programs.find_or_create_by!(name: name) }
      end
    end
  end
end
