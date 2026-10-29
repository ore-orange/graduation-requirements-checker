# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tmpdir'

class CurriculumTest < ActiveSupport::TestCase
  FILE = Rails.root.join('config/curricula/intelligent_informatics/2024.json')

  test '公開済みは同じ slug と年度で2つ作れない' do
    Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
    end
  end

  test '下書きは同じ slug と年度で何件でも作れる' do
    2.times { Curriculum.create!(slug: 'x', admission_year: 2024, document: {}) }
    assert_equal 2, Curriculum.where(slug: 'x').count
  end

  test '公開済みがあっても、同じ slug と年度の下書きを作れる' do
    Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
    draft = Curriculum.create!(slug: 'x', admission_year: 2024, document: {})
    assert_not_predicate draft, :published?
    assert_equal [draft], Curriculum.where(slug: 'x').where(published_at: nil).to_a
  end

  test 'published は公開済みだけを返す' do
    published = Curriculum.create!(slug: 'x', admission_year: 2024, published_at: Time.current)
    Curriculum.create!(slug: 'x', admission_year: 2024)
    assert_equal [published], Curriculum.published.where(slug: 'x').to_a
  end

  test 'document の既定は空のハッシュ' do
    assert_equal({}, Curriculum.create!(slug: 'x', admission_year: 2024).document)
  end

  test 'slug と入学年度は必須' do
    assert_not Curriculum.new(admission_year: 2024).valid?
    assert_not Curriculum.new(slug: 'x').valid?
  end

  test 'seed_from_file は便覧ファイルを公開済みとして入れる' do
    curriculum = Curriculum.seed_from_file(FILE)
    assert_equal 'intelligent_informatics', curriculum.slug
    assert_equal 2024, curriculum.admission_year
    assert_predicate curriculum, :published?
    assert_predicate curriculum, :persisted?
    assert_equal 484, curriculum.document.fetch('courses').size
    assert_equal '2024年度入学 琉球大学工学部工学科 知能情報コース', curriculum.title
  end

  test 'seed_from_file は何度流しても同じ行を更新し、増やさない' do
    first = Curriculum.seed_from_file(FILE)
    count = Curriculum.where(slug: 'intelligent_informatics', admission_year: 2024).count
    second = Curriculum.seed_from_file(FILE)
    assert_equal first.id, second.id
    assert_equal count, Curriculum.where(slug: 'intelligent_informatics', admission_year: 2024).count
    assert_equal 1, Curriculum.published.where(slug: 'intelligent_informatics', admission_year: 2024).count
  end

  test 'seed_from_file は同じ年度の下書きに触れない' do
    draft = Curriculum.create!(slug: 'intelligent_informatics', admission_year: 2024, document: { 'draft' => true })
    Curriculum.seed_from_file(FILE)
    assert_equal({ 'draft' => true }, draft.reload.document)
    assert_not_predicate draft, :published?
  end

  test 'catalogue は便覧の規則を返す' do
    catalogue = Curriculum.seed_from_file(FILE).catalogue
    assert_instance_of GraduationAssessment::Catalogue, catalogue
    assert_includes catalogue.conditions.map(&:id), 'common_total'
  end

  test '壊れた便覧の catalogue は握りつぶさず例外にする' do
    document = JSON.parse(FILE.read)
    document['courses'] << document['courses'].first
    curriculum = Curriculum.create!(slug: 'broken', admission_year: 2024, document: document,
                                    published_at: Time.current)
    assert_raises(ArgumentError) { curriculum.catalogue }
  end

  test 'overwrite: true は既存の公開済みの行をファイルの内容で更新する' do
    existing = curricula(:intelligent_informatics)
    existing.update!(document: { 'edited' => true })
    Curriculum.seed_from_file(FILE, overwrite: true)
    assert_equal 484, existing.reload.document.fetch('courses').size
  end

  test 'overwrite: false は既存の公開済みの行に触れず、無ければ作る' do
    existing = curricula(:intelligent_informatics)
    existing.update!(document: { 'edited' => true })
    assert_no_difference 'Curriculum.count' do
      assert_equal existing, Curriculum.seed_from_file(FILE, overwrite: false)
    end
    assert_equal({ 'edited' => true }, existing.reload.document)

    existing.destroy!
    created = Curriculum.seed_from_file(FILE, overwrite: false)
    assert_predicate created, :published?
    assert_equal 484, created.document.fetch('courses').size
  end

  test '既定では、開発・テストは上書きし、本番は上書きしない' do
    existing = curricula(:intelligent_informatics)
    existing.update!(document: { 'edited' => true })
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new('production')) do
      Curriculum.seed_from_file(FILE)
    end
    assert_equal({ 'edited' => true }, existing.reload.document)

    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new('development')) do
      Curriculum.seed_from_file(FILE)
    end
    assert_equal 484, existing.reload.document.fetch('courses').size
  end

  test 'seed_from_file は、年度として読めないファイル名のパスを例外に入れる' do
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join('some_department', 'notes.json')
      path.dirname.mkpath
      path.write('{}')
      error = assert_raises(ArgumentError) { Curriculum.seed_from_file(path) }
      assert_includes error.message, path.to_s
    end
  end

  test 'seed_from_file は、読めないJSONのパスを例外に入れ、本文は入れない' do
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join('some_department', '2030.json')
      path.dirname.mkpath
      path.write('{ secret-body')
      error = assert_raises(ArgumentError) { Curriculum.seed_from_file(path) }
      assert_includes error.message, path.to_s
      assert_not_includes error.message, 'secret-body'
    end
  end

  test '学部名とコース名は、画面から上げるとき(upload)だけ必須' do
    draft = Curriculum.new(slug: 'x', admission_year: 2025)
    assert draft.valid?
    assert_not draft.valid?(:upload)
    assert_equal %i[faculty_name department_name], draft.errors.attribute_names
  end

  test '画像の置き場は環境ごとに分かれ、テストでは並列のワーカーごとに差し替わる' do
    curriculum = Curriculum.create!(slug: 'x', admission_year: 2025)

    assert_equal Curriculum.images_root.join(curriculum.id.to_s), curriculum.images_dir
    assert_not_equal Rails.root.join('storage/curricula', Rails.env), Curriculum.images_root
    assert_not_equal TimetableUpload.images_root, Curriculum.images_root
    assert_includes Curriculum.images_root.to_s, 'tmp/test_curriculum_images'
  end

  test '下書きを消すと、画像の置き場ごと消える' do
    curriculum = Curriculum.create!(slug: 'x', admission_year: 2025)
    FileUtils.mkdir_p(curriculum.images_dir)
    curriculum.images_dir.join('p1.png').write('png')
    other = Curriculum.create!(slug: 'y', admission_year: 2025)
    FileUtils.mkdir_p(other.images_dir)

    curriculum.destroy!

    refute_path_exists curriculum.images_dir
    assert_path_exists other.images_dir
  end

  test '画像が無い下書きを消しても落ちない' do
    assert_nothing_raised { Curriculum.create!(slug: 'x', admission_year: 2025).destroy! }
  end

  test 'page_image_path は、あるページ画像だけを返し、ページ番号以外では引かない' do
    curriculum = Curriculum.create!(slug: 'x', admission_year: 2025)
    FileUtils.mkdir_p(curriculum.images_dir)
    curriculum.images_dir.join('p2.png').write('png')
    FileUtils.mkdir_p(Curriculum.images_root.join('secret'))
    Curriculum.images_root.join('secret/p1.png').write('secret')

    assert_equal curriculum.images_dir.join('p2.png'), curriculum.page_image_path('2')
    assert_nil curriculum.page_image_path('1')
    ['0', '-1', 'abc', '', nil, '2.5', '1e1', '../secret/p1', '../x/p2', "2\n", '00002x', '9' * 14].each do |bad|
      assert_nil curriculum.page_image_path(bad), "#{bad.inspect} を受けてしまった"
    end
  end

  test 'blank_pages は全ページを skip・pending で並べる' do
    assert_equal [{ 'page' => 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => nil },
                  { 'page' => 2, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => nil }],
                 Curriculum.blank_pages(2)
    assert_empty Curriculum.blank_pages(0)
  end

  test 'blank_pages は、取り出したテキストをページの順に入れる' do
    pages = Curriculum.blank_pages(3, texts: %w[一 二])

    assert_equal ['一', '二', nil], pages.pluck('text')
  end

  test 'assign_page_kinds は送られたページだけ替え、不正なら何も変えない' do
    draft = Curriculum.new(slug: 'x', admission_year: 2025, pages: Curriculum.blank_pages(3))

    draft.assign_page_kinds('2' => 'courses')
    assert_equal %w[skip courses skip], draft.pages.pluck('kind')
    assert_not draft.page_kinds_assignable?('1' => 'requirements', '3' => 'bogus')
    assert_not draft.page_kinds_assignable?('4' => 'courses')
    assert_raises(ArgumentError) { draft.assign_page_kinds('1' => 'requirements', '3' => 'bogus') }
    assert_equal %w[skip courses skip], draft.pages.pluck('kind')
  end
end

