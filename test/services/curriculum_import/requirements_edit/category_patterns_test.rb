# frozen_string_literal: true

require 'test_helper'
require_relative '../../../support/requirements_draft_fixtures'

# 区分の科目番号パターンの候補を、人が採用する。採用は人が押した操作なので、確認済みの科目も科目表から外す
# (読み取り時の絞り込みは「人が触ったものは残す」。向きが逆なのは、押したのが人だから)。
class CategoryPatternsTest < ActiveSupport::TestCase
  include RequirementsDraftFixtures

  setup do
    @curriculum = Curriculum.create!(slug: 'category_patterns', admission_year: 2025, faculty_name: '工学部',
                                     department_name: '工学科 知能情報コース', source_filename: 'handbook.pdf',
                                     pages: [], document: document_with_intel)
  end

  # 知能4xx の5科目(うち1つは人が確認済み、1つは必修)と、知能1xx の必修1科目を、区分 intel に足した文書。
  def document_with_intel
    document = requirements_document
    document['categories'] += [{ 'key' => 'intel', 'label' => '知能系', 'counts_toward_total' => true },
                               { 'key' => 'common', 'label' => '共通', 'counts_toward_total' => true,
                                 'number_patterns' => ['共'] }]
    document['courses'] += [fixture_course('知能401', 'A', 'intel'), fixture_course('知能402', 'B', 'intel'),
                            fixture_course('知能403', 'C', 'intel'),
                            fixture_course('知能404', 'D', 'intel', 'confirmed' => true),
                            fixture_course('知能405', 'E', 'intel', required: true),
                            fixture_course('共101', 'F', 'common'), fixture_course('共102', 'G', 'common'),
                            fixture_course('共103', 'H', 'common')]
    document
  end

  def edit(**params)
    revision = CurriculumImport::RequirementsEdit.revision(@curriculum.document)
    CurriculumImport::RequirementsEdit.new(@curriculum, { revision: revision }.merge(params)).call
  end

  def document_after = @curriculum.reload.document

  def category_after(key) = document_after['categories'].find { |category| category['key'] == key }

  def numbers_after = document_after['courses'].pluck('number')

  test '候補を採用すると、その区分の number_patterns に入る' do
    result = edit(adopt_patterns: { 'intel' => '1' })

    assert result.ok?, result.errors.join('/')
    assert_equal ['知能4'], category_after('intel')['number_patterns']
  end

  # 人が押した値。立てないと、読み直しが読み取り側の区分で上書きする。
  test '候補を採用すると、その区分の confirmed が立つ' do
    edit(adopt_patterns: { 'intel' => '1' })

    assert_equal true, category_after('intel')['confirmed']
    assert_nil category_after('humanities')['confirmed']
  end

  test '採用で条件に当たるようになった科目は、文書から外れる' do
    edit(adopt_patterns: { 'intel' => '1' })

    assert_not_includes numbers_after, '知能401'
    assert_not_includes numbers_after, '知能403'
    # 条件に当たらない科目・判定が個別に見る科目(必修)は残る
    assert_includes numbers_after, '知能405'
    assert_includes numbers_after, '人101'
  end

  test '確認済みの科目も、採用のときは外れる' do
    edit(adopt_patterns: { 'intel' => '1' })

    assert_not_includes numbers_after, '知能404'
  end

  test '採用していない区分の科目は、確認済みでなくても外れない' do
    document = document_with_intel
    document['courses'] << fixture_course('共104', 'I', 'common', 'confirmed' => true)
    @curriculum.update!(document: document)

    edit(adopt_patterns: { 'intel' => '1' })

    assert_includes numbers_after, '共104'
  end

  test '既にパターンを持つ区分には、候補を出さない' do
    review = CurriculumImport::RequirementsReview.new(@curriculum)

    assert_equal [], review.pattern_suggestions_for('common')
    assert_equal ['知能4'], review.pattern_suggestions_for('intel')
  end

  test '既にパターンを持つ区分は、採用の送信も受けない' do
    before = @curriculum.document.deep_dup

    result = edit(adopt_patterns: { 'common' => '1' })

    assert_not result.ok?
    assert_equal before, document_after
  end

  test '採用した件数が、保存の知らせに出る' do
    result = edit(adopt_patterns: { 'intel' => '1' })

    assert_match(/知能系/, result.notes.join)
    assert_match(/4件/, result.notes.join)
    assert_match(/確認済み1件/, result.notes.join)
  end

  test '採用と同じ保存で直した区分の名前は、残る' do
    edit(categories: [{ key: 'intel', label: '知能' }], adopt_patterns: { 'intel' => '1' })

    assert_equal '知能', category_after('intel')['label']
    assert_equal ['知能4'], category_after('intel')['number_patterns']
  end

  # 同じ保存で人がパターンを書いたら、その値が先。候補は「パターンの無い区分」にだけ出す約束なので、採用は断る。
  test '同じ保存でパターンを書いた区分は、採用を断り、何も保存しない' do
    before = @curriculum.document.deep_dup

    result = edit(categories: [{ key: 'intel', number_patterns: '知能9' }], adopt_patterns: { 'intel' => '1' })

    assert_not result.ok?
    assert_equal before, document_after
  end

  test '候補が無い区分や、区分に無いキーは断る' do
    result = edit(adopt_patterns: { 'excluded' => '1', 'nothing' => '1' })

    assert_equal 2, result.problems.size
  end

  # 既存の不変条件。採用が送られない保存は、文書に何も書かない。
  test '採用が送られない・空・オフのときは、文書は1バイトも変わらない' do
    before = @curriculum.document.deep_dup

    [{}, { adopt_patterns: {} }, { adopt_patterns: { 'intel' => '0' } }, { adopt_patterns: '' }].each do |params|
      result = edit(**params)

      assert result.ok?, result.errors.join('/')
      assert_equal before, document_after
    end
  end

  class StubReader
    def initialize(courses) = @courses = courses

    def read_courses(text:, **) = @courses.fetch(text)
  end

  def course_row(number)
    { 'number' => number, 'name' => "科目#{number}", 'credits' => 2, 'category' => 'intel', 'required' => false,
      'requires_approval' => false, 'language' => nil, 'review_reason' => nil, 'roles' => [] }
  end

  # 採用で外した科目(確認済みを含む)を、同じページの読み直しが連れ戻さない。戻ると科目表が再び膨らむ。
  test '採用して外した科目は、同じページを読み直しても戻ってこない' do
    curriculum = Curriculum.create!(
      slug: 'prune_reread', admission_year: 2025, faculty_name: '工学部', department_name: '工学科',
      source_filename: 'handbook.pdf',
      document: { 'categories' => [{ 'key' => 'intel', 'label' => '知能系', 'counts_toward_total' => true }] },
      pages: [{ 'page' => 9, 'kind' => 'courses', 'status' => 'pending', 'error' => nil, 'text' => '科目' }]
    )
    FileUtils.mkdir_p(curriculum.images_dir)
    File.binwrite(curriculum.images_dir.join('p9.png'), "\x89PNG".b)
    rows = %w[知能401 知能402 知能403 知能404].map { |number| course_row(number) }
    reader = StubReader.new('科目' => { 'courses' => rows })
    assert CurriculumImport::ReadPage.new(curriculum, reader: reader).call(9)
    assert_equal 4, curriculum.reload.document['courses'].size
    key = curriculum.document['courses'].find { |course| course['number'] == '知能404' }['key']
    curriculum.with_lock { assert CurriculumImport::CourseEdit.new(curriculum, key: key, confirmed: true).call.ok? }

    revision = CurriculumImport::RequirementsEdit.revision(curriculum.reload.document)
    result = curriculum.with_lock do
      CurriculumImport::RequirementsEdit.new(curriculum, revision: revision, adopt_patterns: { 'intel' => '1' }).call
    end
    assert result.ok?, result.errors.join('/')
    assert_equal [], curriculum.reload.document['courses']

    assert CurriculumImport::ReadPage.new(curriculum, reader: reader).call(9)

    assert_equal [], curriculum.reload.document['courses'].pluck('number')
  ensure
    FileUtils.rm_rf(curriculum.images_dir) if curriculum
  end
end

