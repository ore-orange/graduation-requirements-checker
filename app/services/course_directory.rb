# frozen_string_literal: true

# 学生に見せる科目の名簿。「この区分には、どんな科目があるか」に答える。
#
# 科目の実体は courses テーブルが持つ(履修も予定も Course の行を指す)。便覧の文書は、その科目に区分の札を貼る側で、
# 札は2通りある。
#   1. 便覧に登録された科目(番号から区分が決まらないもの) … 登録の区分・必修・役割・承認・選べるかを正とする。
#   2. 登録の無い科目 … 番号を区分の number_patterns に掛けて決める。決まらなければ名簿に出さない。
# 2で出た科目は、必修でも役割持ちでも承認要でもなく、選べるものとする。
#
# 判定(GraduationAssessment)はこの名簿を使わない。判定は Catalogue と EntryNormalizer の経路で動く。
# 名簿は人と学生に見せるためだけのものなので、ここを変えても判定の数字は動かない。
#
# 載せる Course は、番号があり、学生の自由入力(custom?)でないもの。自由入力の行を入れると、ある学生の打ち間違いが
# 全員のメニューに並ぶ。過年度・他学科の行は入れる(開講年度では絞らない)。
# 同じ番号で名前の違う行は、どちらかを選ばず2件とも出す。Entry が course_id を持つので、呼び手が id で決める。
#
# 1回の描画で区分ごとに何度も呼ばれるので、Course は1つのインスタンスの中で1回だけ読む。
class CourseDirectory
  Entry = Struct.new(:course_id, :number, :name, :credits, :category, :required, :roles, :requires_approval,
                     :selectable)

  # document は便覧の文書。categories が空、あるいは文書が空の下書きでも例外にせず、どの区分も空を返す。
  def initialize(document)
    document = {} unless document.is_a?(Hash)
    @category_keys = Array(document['categories']).grep(Hash).filter_map { |category| category['key'] }
    @patterns = CurriculumImport::NumberPatterns.new(document['categories'])
    @registered = Array(document['courses']).grep(Hash).select { |course| course['number'].present? }
                                            .index_by { |course| course['number'] }
  end

  # 区分の科目。番号順(同じ番号は名前、id の順)。
  def in_category(key) = entries_by_category.fetch(key, [])

  # 番号から決まる区分のキー。登録があればその区分、なければ番号パターン。決まらなければ nil。
  def category_for(number)
    @registered.dig(number, 'category') || @patterns.category_for(number)
  end

  # Course の id から名簿の1件。名簿に無ければ nil。
  def find(course_id) = entries_by_id[course_id]

  # 科目が1件以上ある区分のキー。文書の区分の並びに従い、文書に無い区分(登録だけが指すもの)は最後に足す。
  def categories
    present = entries_by_category.keys
    (@category_keys & present) + (present - @category_keys).sort
  end

  private

  def entries
    @entries ||= Course.where.not(course_number: [nil, '']).where(custom_category: nil)
                       .order(:course_number, :name, :id).filter_map { |course| entry_for(course) }
  end

  def entries_by_category = @entries_by_category ||= entries.group_by(&:category)

  def entries_by_id = @entries_by_id ||= entries.index_by(&:course_id)

  def entry_for(course)
    registered = @registered[course.course_number]
    if registered
      Entry.new(course.id, course.course_number, course.name.presence || registered['name'],
                course.credits || registered['credits'], registered['category'], registered['required'],
                registered['roles'], registered['requires_approval'], registered['selectable'])
    else
      category = @patterns.category_for(course.course_number)
      return nil unless category

      Entry.new(course.id, course.course_number, course.name, course.credits, category, false, [], false, true)
    end
  end
end

