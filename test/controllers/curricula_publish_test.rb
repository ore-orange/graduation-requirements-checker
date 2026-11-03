# frozen_string_literal: true

require 'test_helper'
require_relative '../support/requirements_draft_fixtures'

# 公開の画面。止める理由は画面に並べ、ボタンは公開できるときだけ押せる。警告は読んだと答えるまで公開しない。
# 公開済みは書き換えず、直すときは複製して公開し、差し替える。学生が指している便覧は消せない。
class CurriculaPublishTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures
  include RequirementsScreenHelpers

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    Curriculum.find_each { |curriculum| FileUtils.rm_rf(curriculum.images_dir) }
  end

  def confirmed_document
    requirements_document.tap { |document| document['courses'].each { |course| course['confirmed'] = true } }
  end

  def ready_draft(document: confirmed_document) = draft(document: document)

  def publish(curriculum, **params) = post(publish_curriculum_path(curriculum), params: params, env: ENV_LOCAL)

  def student_on(curriculum)
    @department ||= Faculty.create!(name: '公開画面の学部').departments.create!(name: '公開画面の学科')
    Student.create!(user: User.create!(email: "s-#{SecureRandom.hex(4)}@example.test"), department: @department,
                    admission_year: 2025, curriculum: curriculum)
  end

  test '公開できる下書きには、公開のボタンが出る' do
    record = ready_draft
    show(record)

    assert_response :success
    assert_select '#publish form[action=?]', publish_curriculum_path(record)
    assert_select '#publish input[type=submit][value=公開する]'
    assert_select '#publish [role=alert]', false
  end

  test '止める理由があるうちは、理由を並べ、公開のボタンを出さない' do
    record = draft # どの科目も確認していない
    show(record)

    assert_select '#publish form', false
    assert_select '#publish button[disabled]', text: '公開する'
    assert_select '#publish [role=alert] li', text: /確認し終えていない科目が10件/
    assert_select '#publish [role=alert] li', text: /「確認した」/
  end

  test '止める理由があるまま公開しようとしても、何も変わらず、理由が返る' do
    record = draft
    publish(record)

    assert_redirected_to curriculum_path(record, anchor: 'publish')
    assert_match '公開できませんでした', flash[:alert]
    assert_match '確認し終えていない', flash[:alert]
    assert_not_predicate record.reload, :published?
  end

  test '公開すると一覧に戻り、下書きは公開済みになって確認用の欄が消える' do
    record = ready_draft
    publish(record)

    assert_redirected_to requirements_path
    assert_predicate record.reload, :published?
    assert(record.document['courses'].none? { |course| course.key?('confirmed') })
  end

  test '警告があれば、読んだと答える箱が出て、答えなしでは公開されない' do
    document = confirmed_document
    document['courses'][0]['source_page'] = ''
    record = ready_draft(document: document)
    show(record)

    assert_select '#publish input[type=checkbox][name=acknowledged][required]'
    publish(record)

    assert_redirected_to curriculum_path(record, anchor: 'publish')
    assert_not_predicate record.reload, :published?

    digest = CurriculumImport::Publication.new(record).digest
    publish(record, acknowledged: digest)

    assert_predicate record.reload, :published?
  end

  test '公開済みの便覧は、公開の操作を受けない' do
    record = ready_draft
    record.publish!
    publish(record)

    assert_redirected_to requirements_path
    assert_match '開けません', flash[:alert]
  end

  test '同じ識別名・年度の公開済みがあれば、差し替えの確認の箱が出て、選ばないと公開されない' do
    first = ready_draft.tap(&:publish!)
    student = student_on(first)
    second = ready_draft
    show(second)

    assert_select '#publish input[type=checkbox][name=replace][required]'
    assert_select '#publish', text: /学生1人/
    publish(second)

    assert_not_predicate second.reload, :published?
    assert_equal first.id, student.reload.curriculum_id

    publish(second, replace: '1')

    assert_predicate second.reload, :published?
    assert_equal second.id, student.reload.curriculum_id
    assert_not_predicate first.reload, :published?
  end

  test '学生が指している公開済みの便覧は消せない' do
    published = ready_draft.tap(&:publish!)
    student_on(published)

    assert_no_difference('Curriculum.count') { delete curriculum_path(published), env: ENV_LOCAL }
    assert_predicate published.reload, :published?
  end

  test '下書きは消せる' do
    record = ready_draft

    assert_difference('Curriculum.count', -1) { delete curriculum_path(record), env: ENV_LOCAL }
  end

  # ---- 複製して直す ----

  test '公開済みの便覧を選ぶと、「この卒業要件を編集する」が出る' do
    published = curricula(:intelligent_informatics)
    get requirements_path(faculty: published.faculty_name, department: published.department_name,
                          admission_year: published.admission_year), env: ENV_LOCAL

    assert_select 'form[action=?]', duplicate_curriculum_path(published)
  end

  test '公開済みを複製すると、document をコピーした下書きができ、公開済みの行は変わらない' do
    published = curricula(:intelligent_informatics)
    before = published.reload.attributes

    assert_difference('Curriculum.drafts.count', 1) { post duplicate_curriculum_path(published), env: ENV_LOCAL }

    copy = Curriculum.drafts.order(:id).last
    assert_redirected_to curriculum_path(copy)
    assert_equal published.document.except('courses'), copy.document.except('courses')
    assert_equal published.document['courses'].size, copy.document['courses'].size
    assert_equal before, published.reload.attributes
  end

  test '複製した下書きは、直さなくても公開でき、差し替えになる。科目は確認済みで、警告も出ない' do
    published = curricula(:intelligent_informatics)
    student = student_on(published)
    post duplicate_curriculum_path(published), env: ENV_LOCAL
    copy = Curriculum.drafts.order(:id).last
    publication = CurriculumImport::Publication.new(copy, replace: true)

    assert_empty publication.blocking_reasons
    assert_empty publication.warnings
    assert_not_predicate copy, :publishable?

    publish(copy, replace: '1')

    assert_predicate copy.reload, :published?
    assert_equal copy.id, student.reload.curriculum_id
    assert_equal published.document, copy.document, '直していない複製を公開しても、文書は変わらない'
  end

  test '下書きは複製できない' do
    record = ready_draft

    assert_no_difference('Curriculum.count') { post duplicate_curriculum_path(record), env: ENV_LOCAL }
    assert_redirected_to requirements_path
  end

  test '差し替えで下書きに戻った便覧は、科目が確認済みのまま戻る' do
    first = ready_draft
    publish(first)
    second = ready_draft
    publish(second, replace: '1')

    demoted = first.reload
    assert_not_predicate demoted, :published?
    assert(demoted.document['courses'].all? { |course| course['confirmed'] == true })
  end

  # ---- まとめて確認する ----

  test '確認していない科目が残る区分には、件数入りの「まとめて確認する」が出る' do
    record = draft # どの科目も確認していない(humanities に3件)
    show(record)

    # 行ごとの操作と同じく、共有のフォーム(course_action_form)に formaction だけを足す(専用のフォームは置かない)。
    assert_select "#course-category-humanities button[formaction^='#{bulk_confirm_courses_curriculum_path(record)}']",
                  text: 'まとめて確認する(3科目)'
  end

  test '全部確認済みの区分には、まとめて確認するボタンが出ない' do
    record = ready_draft # 全科目を確認済みにした下書き
    show(record)

    assert_select '#course-category-humanities button[formaction*=bulk_confirm]', false
  end

  test 'まとめて確認すると、その区分の未確認の科目がすべて確認済みになり、区分へ戻る' do
    record = draft.reload # GET で開いたときと同じ(DBから読み直した)並びにそろえる
    rev = CurriculumImport::CoursesReview.new(CurriculumImport::RequirementsReview.new(record)).section_revision('humanities')

    patch bulk_confirm_courses_curriculum_path(record), params: { category: 'humanities', rev: rev }, env: ENV_LOCAL

    assert_redirected_to curriculum_path(record, anchor: 'course-category-humanities')
    assert_match '3科目をまとめて確認済みにしました', flash[:notice]
    humanities = record.reload.document['courses'].select { |course| course['category'] == 'humanities' }
    assert(humanities.all? { |course| CurriculumImport::CourseEdit.confirmed?(course) })
  end

  test '画面を開いたあとに区分の中身が変わっていれば、まとめて確認は何も変えず断る' do
    record = draft.reload
    rev = CurriculumImport::CoursesReview.new(CurriculumImport::RequirementsReview.new(record)).section_revision('humanities')
    document = record.document.deep_dup
    document['courses'][0]['name'] = '哲学(改)'
    record.update!(document: document)

    patch bulk_confirm_courses_curriculum_path(record), params: { category: 'humanities', rev: rev }, env: ENV_LOCAL

    assert_redirected_to curriculum_path(record, anchor: 'course-category-humanities')
    assert_match '変わっています', flash[:alert]
    assert(record.reload.document['courses'].none? { |course| course['confirmed'] })
  end

  test 'まとめて確認しても、確認済みの下書きは引き続き公開できる' do
    record = draft.reload
    rev = CurriculumImport::CoursesReview.new(CurriculumImport::RequirementsReview.new(record)).section_revision('humanities')
    %w[english required_core fusion excluded].each do |category|
      r = CurriculumImport::CoursesReview.new(CurriculumImport::RequirementsReview.new(record)).section_revision(category)
      patch bulk_confirm_courses_curriculum_path(record), params: { category: category, rev: r }, env: ENV_LOCAL
    end
    patch bulk_confirm_courses_curriculum_path(record), params: { category: 'humanities', rev: rev }, env: ENV_LOCAL

    assert_predicate record.reload, :publishable?
  end

  # ---- 警告の案内 ----

  test '警告が20件を超えると、要件表の確認への案内が出る' do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    document['courses'] = document['courses'].first(20) # 実物から20件だけ残すと、警告が20件を超える(Task 20 で確認済み)
    document['courses'].each { |course| course['confirmed'] = true }
    record = Curriculum.create!(slug: 'tiny', admission_year: 2024, faculty_name: '工学部', department_name: '工学科',
                                source_filename: 'handbook.pdf', document: document)
    publication = CurriculumImport::Publication.new(record)
    assert_operator publication.warnings.size, :>, 20

    show(record)

    assert_select '#publish a[href="#requirements_findings"]', text: '要件表の確認の指摘一覧'
  end
end

