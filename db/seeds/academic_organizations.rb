# frozen_string_literal: true

# 講義の分類に使う学部・学科のマスタ。何度流しても増えない。
#
# この一覧は大学の公式サイト以外の情報源をもとに書いたもので、学科名と構成は年度によって変わる。
# 直すときは、下の ORGANIZATIONS だけを変えればよい。
# 名前を直したときは、seedを流すだけでは古い行が残るので、該当の行をUPDATEすること
# (学部・学科の名前は一意なので、同じ名前の行が2つできることはない)。
module AcademicOrganizations
  ORGANIZATIONS = {
    '人文社会学部' => ['国際法政学科', '人間社会学科', '琉球アジア文化学科'],
    '国際地域創造学部' => ['国際地域創造学科'],
    '教育学部' => ['学校教育教員養成課程'],
    '理学部' => ['数理科学科', '物質地球科学科', '海洋自然科学科'],
    '医学部' => ['医学科', '保健学科'],
    '工学部' => ['工学科'],
    '農学部' => ['亜熱帯地域農学科', '亜熱帯農林環境科学科', '地域農業工学科', '亜熱帯生物資源科学科']
  }.freeze

  def self.load!
    ORGANIZATIONS.each do |faculty_name, department_names|
      faculty = Faculty.find_or_create_by!(name: faculty_name)
      department_names.each { |name| faculty.departments.find_or_create_by!(name: name) }
    end
  end
end
