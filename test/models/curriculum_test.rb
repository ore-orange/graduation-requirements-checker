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

  # プルダウンは学部名・学科コース名で選択肢を作る。文書が持つので、ファイルからの seed でも画面からの取り込みでも同じ値が入る。
  test 'ファイルから読み込んだ便覧にも学部名と学科コース名が入る' do
    curriculum = Curriculum.seed_from_file(FILE)

    assert_equal '工学部', curriculum.faculty_name
    assert_equal '工学科 知能情報コース', curriculum.department_name
    assert_equal '工学部', curriculum.document['faculty_name']
    assert_equal '工学科 知能情報コース', curriculum.document['department_name']
    # department は slug(機械用の識別名)のまま。department_name と取り違えない。
    assert_equal 'intelligent_informatics', curriculum.document['department']
  end

  test '2024年度と2025年度のファイルは、同じ学部名・学科コース名を持つ(プルダウンで1つの学科にまとまる)' do
    names = %w[2024 2025].map do |year|
      document = JSON.parse(Rails.root.join("config/curricula/intelligent_informatics/#{year}.json").read)
      document.values_at('faculty_name', 'department_name')
    end

    assert_equal [['工学部', '工学科 知能情報コース']] * 2, names
  end

  test 'seed_from_file は、既存の行の学部名・学科コース名が空でも、overwrite のときはファイルの値で埋める' do
    existing = curricula(:intelligent_informatics)
    existing.update!(faculty_name: nil, department_name: nil)

    Curriculum.seed_from_file(FILE, overwrite: true)

    assert_equal '工学部', existing.reload.faculty_name
    assert_equal '工学科 知能情報コース', existing.department_name
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

  # ---- 識別名(slug)は人に入力させず、学部名・学科コース名から決める ----

  def upload_draft(faculty: '工学部', department: '工学科 知能情報コース', year: 2026, slug: nil)
    draft = Curriculum.new(slug: slug, admission_year: year, faculty_name: faculty, department_name: department,
                           source_filename: 'handbook.pdf', pages: [])
    draft.save_upload!
    draft
  end

  test '同じ学部名・学科コース名の便覧が既にあれば、その識別名を引き継ぐ(同じ課程の別の年度になる)' do
    assert_equal 'intelligent_informatics', upload_draft.slug
  end

  test '学部名・学科コース名が無い組み合わせには、形の正しい新しい識別名ができる' do
    draft = upload_draft(faculty: '農学部', department: '亜熱帯農林環境科学科')

    assert_match Curriculum::SLUG_FORMAT, draft.slug
    assert_not_equal 'intelligent_informatics', draft.slug
    assert_equal 1, Curriculum.where(slug: draft.slug).count
  end

  test '違う課程には違う識別名が付き、同じ新しい課程を続けて上げると同じ識別名になる' do
    first = upload_draft(faculty: '農学部', department: '亜熱帯農林環境科学科')
    other = upload_draft(faculty: '農学部', department: '亜熱帯地域農学科')
    again = upload_draft(faculty: '農学部', department: '亜熱帯農林環境科学科', year: 2027)

    assert_not_equal first.slug, other.slug
    assert_equal first.slug, again.slug
  end

  test '名前の前後や途中の余分な空白(全角を含む)は揃えるので、同じ課程として識別名を引き継ぐ' do
    draft = upload_draft(faculty: " 工学部\u3000", department: "工学科\u3000 知能情報コース ")

    assert_equal 'intelligent_informatics', draft.slug
    assert_equal ['工学部', '工学科 知能情報コース'], [draft.faculty_name, draft.department_name]
  end

  test '識別名は渡されても信用しない(画面に欄が無いので、決めるのは学部名・学科コース名だけ)' do
    assert_equal 'intelligent_informatics', upload_draft(slug: 'forged').slug
  end

  test '識別名を決めるあいだ、同じ課程の取り込みは1つずつにする(同じ新課程の識別名が割れないように)' do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }
    upload_draft(faculty: '農学部', department: '亜熱帯農林環境科学科')
    ActiveSupport::Notifications.unsubscribe(subscriber)

    lock = statements.index { |sql| sql.include?('pg_advisory_xact_lock') }
    insert = statements.index { |sql| sql.start_with?('INSERT INTO "curricula"') }
    assert lock && insert && lock < insert, 'ロックを取ってから保存していない'
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

