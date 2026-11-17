# frozen_string_literal: true

# 学生の所属と講義の分類に使う、学部・学科・コースのマスタ。何度流しても増えない。
#
# この一覧は大学の公式サイト以外の情報源をもとに書いたもので、学科名と構成は年度によって変わる。
# 直すときは、下の ORGANIZATIONS だけを変えればよい。
# 名前を直したときは、seedを流すだけでは古い行が残るので、該当の行をUPDATEすること
# (学部・学科の名前は一意なので、同じ名前の行が2つできることはない)。
#
# コースは卒業要件を用意したものだけを並べる。値は config/curricula/<値>/<入学年度>.json を指す。
# 用意していない学科は空にしておく。コースが無い学科には、まだ学生を登録できない。
module AcademicOrganizations
  ORGANIZATIONS = {
    '人文社会学部' => { '国際法政学科' => {}, '人間社会学科' => {}, '琉球アジア文化学科' => {} },
    '国際地域創造学部' => { '国際地域創造学科' => {} },
    '教育学部' => { '学校教育教員養成課程' => {} },
    '理学部' => { '数理科学科' => {}, '物質地球科学科' => {}, '海洋自然科学科' => {} },
    '医学部' => { '医学科' => {}, '保健学科' => {} },
    '工学部' => { '工学科' => { '知能情報コース' => 'intelligent_informatics' } },
    '農学部' => { '亜熱帯地域農学科' => {}, '亜熱帯農林環境科学科' => {},
                  '地域農業工学科' => {}, '亜熱帯生物資源科学科' => {} }
  }.freeze

  def self.load!
    ORGANIZATIONS.each do |faculty_name, departments|
      faculty = Faculty.find_or_create_by!(name: faculty_name)
      departments.each { |name, programs| load_department!(faculty, name, programs) }
    end
  end

  def self.load_department!(faculty, name, programs)
    department = faculty.departments.find_or_create_by!(name: name)
    programs.each do |program_name, curriculum_slug|
      # カリキュラムの指し先は毎回ならす。欠けていると画面が出せない。
      department.programs.find_or_initialize_by(name: program_name)
                .update!(curriculum_slug: curriculum_slug)
    end
  end
  private_class_method :load_department!
end
