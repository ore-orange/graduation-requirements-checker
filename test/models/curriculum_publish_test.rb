# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require_relative '../support/requirements_draft_fixtures'

# 下書きを公開する関門。公開は、その文書が学生に「卒業できます」と言い始める瞬間なので、危ない文書は止め、
# 止めるときは事務の人が直せる理由を言う。公開した文書は、実物の2024年度の便覧と同じ欄だけを持つ。
class CurriculumPublishTest < ActiveSupport::TestCase
  include RequirementsDraftFixtures

  REAL = Rails.root.join('config/curricula/intelligent_informatics/2024.json')

  DRAFT_COURSE_KEYS = %w[confirmed read_as read_fp added_by_hand approval_by_note review_again].freeze

  teardown { Curriculum.find_each { |curriculum| FileUtils.rm_rf(curriculum.images_dir) } }

  # すべての科目を確認し終えた、止める指摘の無い下書き。
  def ready_draft(document: requirements_document, slug: 'x', year: 2025)
    document = document.deep_dup
    document['courses'].each { |course| course['confirmed'] = true }
    Curriculum.create!(slug: slug, admission_year: year, faculty_name: '工学部', department_name: '工学科',
                       source_filename: 'handbook.pdf', pages: pages_of(document), document: document)
  end

  def pages_of(document)
    contributed = { 'rules' => document['rules'].pluck('id'), 'groups' => document.dig('display', 'groups').pluck('id'),
                    'subtotals' => [], 'total_credits' => true }
    [{ 'page' => 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => '表紙' },
     { 'page' => 2, 'kind' => 'requirements', 'status' => 'read', 'error' => nil, 'text' => '要件',
       'contributed' => contributed }]
  end

  def real_document = JSON.parse(REAL.read)

  def student_for(curriculum)
    @department ||= Faculty.create!(name: '公開テスト学部').departments.create!(name: '公開テスト学科')
    Student.create!(user: User.create!(email: "s-#{SecureRandom.hex(4)}@example.test"), department: @department,
                    admission_year: 2025, curriculum: curriculum)
  end

  # ---- 止めるもの ----

  test '確認し終えた下書きは公開でき、止める理由は無い' do
    draft = ready_draft

    assert_predicate draft, :publishable?
    assert_empty draft.blocking_reasons
  end

  test '確認し終えていない科目があれば公開できない。理由は件数と科目を言う' do
    draft = ready_draft
    document = draft.document.deep_dup
    document['courses'][0].delete('confirmed')
    document['courses'][1]['confirmed'] = false
    draft.update!(document: document)

    assert_not_predicate draft, :publishable?
    reason = draft.blocking_reasons.find { |text| text.include?('確認し終えていない') }
    assert_includes reason, '2件'
    assert_includes reason, '人101'
    assert_includes reason, '「確認した」'
  end

  test '確認したあとに承認の注記が付いた科目(review_again)は、確認し終えていない' do
    draft = ready_draft
    document = draft.document.deep_dup
    document['courses'][0]['review_again'] = true
    draft.update!(document: document)

    assert_not_predicate draft, :publishable?
    assert_predicate(draft.blocking_reasons, :any?)
    assert(draft.blocking_reasons.any? { |text| text.include?('1件') })
  end

  test '止める突き合わせが残っていれば公開できない。理由は場所と対象を言う' do
    document = requirements_document
    document['display']['groups'][2]['rows'] = [] # 工学融合の区分が、どの行にも出てこない
    draft = ready_draft(document: document)

    assert_not_predicate draft, :publishable?
    reason = draft.blocking_reasons.find { |text| text.include?('画面のどの行にも出てきません') }
    assert reason, draft.blocking_reasons.inspect
    assert_includes reason, '【要件表の確認・画面の表】'
    assert_includes reason, 'fusion'
  end

  test '科目が無い便覧・規則が無い便覧・display が無い便覧は、科目を確認済みにしても公開できない' do
    # 科目は先に確認済みにしておく。そうしないと、止めた理由が「確認していない科目がある」なのか
    # 「骨組みが欠けている」(DocumentChecks)なのか見分けが付かない。
    cases = { '科目が1つもありません' => ->(d) { d['courses'] = [] },
              '判定の規則が1つもありません' => ->(d) { d['rules'] = [] },
              '画面の要件表(display)がありません' => ->(d) { d.delete('display') } }
    cases.each do |fragment, breaker|
      document = requirements_document
      document['courses'].each { |course| course['confirmed'] = true }
      document.tap(&breaker)
      draft = Curriculum.create!(slug: 'y', admission_year: 2025, document: document,
                                 pages: pages_of(requirements_document))

      assert_not_predicate draft, :publishable?
      assert(draft.blocking_reasons.any? { |text| text.include?(fragment) }, draft.blocking_reasons.inspect)
    end
  end

  test '壊れた document は、落とさず公開できないと答える' do
    [{}, { 'courses' => 'x' }, { 'courses' => [1], 'rules' => 5 }].each do |document|
      draft = Curriculum.create!(slug: 'z', admission_year: 2025, document: document)

      assert_not_predicate draft, :publishable?
      assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }
      assert_not_predicate draft.reload, :published?
    end
  end

  test '公開済みの便覧は、もう一度公開できない' do
    draft = ready_draft
    draft.publish!

    assert_not_predicate draft, :publishable?
    assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }
  end

  test '止める理由があるまま公開しようとすると、何も変えずに断る' do
    draft = ready_draft
    document = draft.document.deep_dup
    document['courses'][0].delete('confirmed')
    draft.update!(document: document)
    FileUtils.mkdir_p(draft.images_dir)

    error = assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }

    assert_predicate error.reasons, :any?
    assert_not_predicate draft.reload, :published?
    assert_predicate draft.pages, :any?
    assert_path_exists draft.images_dir
  end

  # ---- 公開した文書 ----

  test '公開すると確認用の欄とページ画像が消える' do
    draft = ready_draft
    FileUtils.mkdir_p(draft.images_dir)
    File.binwrite(draft.images_dir.join('p1.png'), 'x')

    draft.publish!

    assert_predicate draft, :published?
    assert_not draft.document['courses'].first.key?('confirmed')
    assert_empty draft.pages
    assert_nil draft.source_filename
    assert_nil draft.import_error
    refute_path_exists Curriculum.images_root.join(draft.id.to_s)
    assert_equal draft.document, draft.reload.document
  end

  test '公開しても review_reason は残る' do
    document = requirements_document
    document['courses'][0]['review_reason'] = '単位が読み取れません'
    draft = ready_draft(document: document)
    draft.publish!

    assert(draft.document['courses'].any? { |course| course['review_reason'].present? })
  end

  test '科目の確認用の欄は、すべて公開から落ちる' do
    document = requirements_document
    document['courses'][0].merge!('read_as' => 'x', 'read_fp' => 'y', 'added_by_hand' => true,
                                  'approval_by_note' => true, 'review_again' => true)
    draft = ready_draft(document: document)
    draft.update!(document: draft.document.deep_dup.tap { |d| d['courses'][0].delete('review_again') })
    draft.publish!

    assert(draft.document['courses'].none? { |course| course.keys.intersect?(DRAFT_COURSE_KEYS) })
  end

  test '公開した文書は、実物の2024年度の便覧と同じ欄だけを持つ(下書きの印を全部付けても、元の文書に戻る)' do
    marked = real_document
    marked['courses'].each_with_index do |course, index|
      course.merge!('confirmed' => true, 'read_as' => "n#{index}", 'read_fp' => 'fp', 'added_by_hand' => false,
                    'approval_by_note' => true, 'review_again' => false, 'draft_only' => 1)
    end
    marked['categories'].each { |category| category['confirmed'] = true }
    marked['sources'].each { |source| source['confirmed'] = true }
    mark_rules(marked['rules'])
    marked['display']['groups'].each do |group|
      group['confirmed'] = true
      group['rows'].each { |row| row['confirmed'] = true }
    end
    marked['display']['subtotals'].each { |subtotal| subtotal['confirmed'] = true }
    marked.merge!('approval_notes' => [{ 'scope' => 'page', 'page' => 3, 'text' => '承認' }], 'removed_by_human' => [],
                  'annotation_decisions' => { 'a' => 'ignore' }, 'something_new' => 1)
    draft = ready_draft(document: marked, slug: 'real_copy', year: 2024)

    draft.publish!

    assert_equal real_document.merge('department' => 'real_copy'), draft.reload.document
  end

  test '文書の department と admission_year は、便覧の行に合わせる' do
    document = requirements_document.merge('department' => 'sample', 'admission_year' => 1999)
    draft = ready_draft(document: document, slug: 'dept_a', year: 2026)
    draft.publish!

    assert_equal 'dept_a', draft.document['department']
    assert_equal 2026, draft.document['admission_year']
  end

  test '無い欄は、公開でも無いまま(null を足さない)' do
    document = requirements_document
    document.delete('sources')
    document['display'].delete('subtotals')
    draft = ready_draft(document: document)
    draft.publish!

    assert_not draft.document.key?('sources')
    assert_not draft.document['display'].key?('subtotals')
    assert_nothing_raised { draft.catalogue }
  end

  test '公開した文書は、読み込めて判定が走る' do
    draft = ready_draft
    draft.publish!

    snapshot = GraduationAssessment::Evaluation.new(draft.catalogue).call([], [], [])
    assert_not_equal :satisfied, snapshot.status
  end

  # ---- 警告の確認 ----

  test '警告があれば、見たと答えないと公開できない。答えは警告の一覧の指紋' do
    document = requirements_document
    document['courses'][0]['source_page'] = '' # 出典が無い(警告)
    draft = ready_draft(document: document)
    publication = CurriculumImport::Publication.new(draft)

    assert_predicate draft, :publishable?
    assert_predicate publication.warnings, :any?
    assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }
    assert_raises(CurriculumImport::Publication::Refused) { draft.publish!(acknowledged: 'stale') }
    assert_not_predicate draft.reload, :published?

    draft.publish!(acknowledged: publication.digest)

    assert_predicate draft, :published?
  end

  test '警告の一覧が変わると、前の指紋ではもう公開できない(答えの使い回しを防ぐ)' do
    document = requirements_document
    document['courses'][0]['source_page'] = '' # 出典が無い(警告その1)
    draft = ready_draft(document: document)
    old_digest = CurriculumImport::Publication.new(draft).digest

    # 別の警告が増える(単位が0)。読んだはずの一覧には無かった警告なので、前の指紋はもう当てはまらない。
    updated = draft.document.deep_dup
    updated['courses'][1]['credits'] = 0
    draft.update!(document: updated)

    assert_not_equal old_digest, CurriculumImport::Publication.new(draft).digest
    assert_raises(CurriculumImport::Publication::Refused) { draft.publish!(acknowledged: old_digest) }
    assert_not_predicate draft.reload, :published?

    draft.publish!(acknowledged: CurriculumImport::Publication.new(draft).digest)

    assert_predicate draft, :published?
  end

  test '下書き自体には止める指摘が無くても、公開する形にした文書が壊れていれば止める(2回検める網)' do
    draft = ready_draft
    broken = { 'broken' => true } # courses も rules も無い形。本物の PublishedDocument.build はこうは作らないが、
    # 「公開する形にした文書も同じ検査にかける」が外れていないかを、ここで直に確かめる。

    CurriculumImport::PublishedDocument.stub(:build, broken) do
      assert_empty CurriculumImport::Validation.for(draft).call, '下書き自体は、公開を止める指摘が無い'
      assert_not_predicate draft, :publishable?
      assert(draft.blocking_reasons.any? { |text| text.include?('courses がありません') }, draft.blocking_reasons.inspect)
      assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }
    end
    assert_not_predicate draft.reload, :published?
  end

  test '警告が無ければ、確認の答えは要らない' do
    draft = ready_draft

    assert_empty CurriculumImport::Publication.new(draft).warnings
    assert_nothing_raised { draft.publish! }
  end

  test '科目がごく少ない便覧は止まらないが、警告が出て確認が要る' do
    document = real_document
    document['courses'] = document['courses'].first(20)
    draft = ready_draft(document: document, slug: 'tiny', year: 2024)
    publication = CurriculumImport::Publication.new(draft)

    assert_predicate draft, :publishable?
    assert_operator publication.warnings.size, :>, 5
    assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }
  end

  # ---- 同じ識別名・入学年度 ----

  test '同じ slug と年度の公開済みが既にあれば公開できない' do
    first = ready_draft
    first.publish!
    second = ready_draft

    assert_not_predicate second, :publishable?
    assert(second.blocking_reasons.any? { |text| text.include?('公開済みの便覧が既にあります') })
    assert_raises(CurriculumImport::Publication::Refused) { second.publish! }
    assert_equal [first], Curriculum.published.where(slug: 'x').to_a
  end

  test '別の年度なら、同じ slug でも公開できる' do
    ready_draft.publish!

    assert_predicate ready_draft(year: 2026), :publishable?
  end

  test '差し替えると、公開済みは下書きに戻り、学生は新しい便覧に付け替わる' do
    first = ready_draft
    first.publish!
    students = Array.new(2) { student_for(first) }
    second = ready_draft

    assert second.publishable?(replace: true)
    second.publish!(replace: true)

    assert_predicate second.reload, :published?
    assert_not_predicate first.reload, :published?
    assert_equal [second.id], students.map { |student| student.reload.curriculum_id }.uniq
    assert_equal [second], Curriculum.published.where(slug: 'x', admission_year: 2025).to_a
  end

  test '差し替えで下書きに戻った便覧は、科目が確認済みのまま戻るので、直さなくても再び公開できる' do
    first = ready_draft
    first.publish!
    second = ready_draft
    second.publish!(replace: true)

    demoted = first.reload
    assert_not_predicate demoted, :published?
    assert(demoted.document['courses'].all? do |course|
      course['confirmed'] == true
    end, '複製(Duplicate)と同じ理由で、484科目を確認し直させない')
    assert demoted.publishable?(replace: true)
  end

  test '差し替えの途中で失敗したら、何も変わらない' do
    first = ready_draft
    first.publish!
    student = student_for(first)
    second = ready_draft

    Student.stub(:where, ->(*) { raise 'boom' }) do
      assert_raises(RuntimeError) { second.publish!(replace: true) }
    end

    assert_predicate first.reload, :published?
    assert_not_predicate second.reload, :published?
    assert_equal first.id, student.reload.curriculum_id
  end

  test '判定のあとに別の人が先に公開しても、落とさず理由で断る' do
    draft = ready_draft
    draft.stub(:update!, ->(*) { raise ActiveRecord::RecordNotUnique, 'duplicate' }) do
      error = assert_raises(CurriculumImport::Publication::Refused) { draft.publish! }

      assert_includes error.reasons.first, '先に公開されました'
    end
  end

  # ---- 学生と便覧 ----

  test '学生は下書きの便覧を指せない' do
    student = student_for(ready_draft.tap(&:publish!))
    student.curriculum = ready_draft(year: 2030)

    assert_not_predicate student, :valid?
  end

  test '学生が指している便覧は消せない' do
    published = ready_draft.tap(&:publish!)
    student_for(published)

    assert_no_difference('Curriculum.count') { assert_not published.destroy }
    assert_includes published.errors.map(&:type), :'restrict_dependent_destroy.has_many'
  end

  test '学生がいなければ、下書きは消せる' do
    draft = ready_draft

    assert_difference('Curriculum.count', -1) { draft.destroy }
  end

  private

  def mark_rules(rules)
    rules.each do |rule|
      rule['confirmed'] = true
      mark_rules(rule['options']) if rule['options']
      mark_rules(rule['conditions']) if rule['conditions']
    end
  end
end

