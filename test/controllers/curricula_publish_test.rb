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

  test '公開済みの一覧に「複製して直す」が出る' do
    DemoData.load! # 卒業要件の画面は学生の便覧を読む
    get requirements_path, env: ENV_LOCAL

    target = duplicate_curriculum_path(curricula(:intelligent_informatics))

    assert_select '[data-published-curricula] form[action=?]', target
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
end

