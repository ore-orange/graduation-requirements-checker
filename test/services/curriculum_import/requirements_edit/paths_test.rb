# frozen_string_literal: true

require 'test_helper'
require_relative '../../../support/requirements_draft_fixtures'

# 経路(one_of_paths)を、役割キーではなく科目で選ぶ(設計書 項目3-1)。
#
# いままでの画面は、便覧じゅうの役割キーを英語のまま並べたチェックだった。
# 「日本語表現法入門を修得していること」を表すのに、関係のない微分積分学や物理学の役割も混ざって出ていた。
#
# 役割キーはアプリが裏で振る。画面は科目の key を送り、ここが役割に直す。
# 判定(Catalogue#role_candidates)は courses[].roles しか見ないので、役割は科目にも足す。
class PathsTest < ActiveSupport::TestCase
  include RequirementsDraftFixtures

  setup do
    document = requirements_document
    document['rules'] << fixture_rule('english_required', 'one_of_paths', paths: [%w[role_a]])
    @curriculum = Curriculum.create!(slug: 'paths', admission_year: 2025, faculty_name: '工学部',
                                     department_name: '工学科 知能情報コース', source_filename: 'handbook.pdf',
                                     pages: [], document: document)
  end

  def edit(**params)
    revision = CurriculumImport::RequirementsEdit.revision(@curriculum.document)
    CurriculumImport::RequirementsEdit.new(@curriculum, { revision: revision }.merge(params)).call
  end

  def document_after = @curriculum.reload.document

  def rule_after(id) = document_after['rules'].find { |rule| rule['id'] == id }

  def course_after(key) = document_after['courses'].find { |course| course['key'] == key }

  def index_of(id) = @curriculum.document['rules'].index { |rule| rule['id'] == id }

  def save_paths(rows)
    edit(rules: { '0' => { id: 'english_required', paths: rows } })
  end

  # 人101 は roles: ['role_a'] を持っている。人103 は役割を持っていない。

  test '役割をすでに持つ科目を選ぶと、その役割が経路に入る' do
    result = save_paths('a' => { roles: %w[course_人101] })

    assert_predicate result, :ok?
    assert_equal [%w[role_a]], rule_after('english_required')['paths']
  end

  test '役割を持たない科目を選ぶと、その科目の key が役割になり、科目にも足される' do
    result = save_paths('a' => { roles: %w[course_人103] })

    assert_predicate result, :ok?
    assert_equal [%w[course_人103]], rule_after('english_required')['paths']
    assert_equal ['course_人103'], course_after('course_人103')['roles']
  end

  # 「確認した」印は、その科目の単位・区分をPDFと見比べたという意味。要件表の画面が勝手に付けると、
  # AI の読み直しがその科目の単位を直せなくなる(科目表の画面のワークフローに属する値)。
  test '役割を足した科目に、人が確認した印は付けない' do
    save_paths('a' => { roles: %w[course_人103] })

    assert_not CurriculumImport::CourseEdit.confirmed?(course_after('course_人103'))
  end

  test '経路から科目を外すと、どの経路も名指ししていない役割は科目からも消える' do
    save_paths('a' => { roles: %w[course_人103] })
    assert_equal ['course_人103'], course_after('course_人103')['roles']

    save_paths('a' => { roles: %w[course_人101] })

    assert_empty Array(course_after('course_人103')['roles'])
  end

  # fixture の path_rule が role_b を名指ししている。english_required から外しても、消してはいけない。
  test 'ほかの決まりがまだ名指ししている役割は、科目から消さない' do
    save_paths('a' => { roles: %w[course_人102] })
    assert_equal ['role_b'], course_after('course_人102')['roles']

    save_paths('a' => { roles: %w[course_人101] })

    assert_equal ['role_b'], course_after('course_人102')['roles'], 'path_rule がまだ role_b を指している'
  end

  # 保存できなかった送信を画面に戻すと、古い値が混ざりうる。科目表に無い key は、黙って落とさず断る。
  test '科目表に無い key が送られたら、保存せず問題にする' do
    result = save_paths('a' => { roles: %w[course_存在しない] })

    assert_not_predicate result, :ok?
    assert_equal requirements_document['rules'].size + 1, document_after['rules'].size
    assert_match(/科目表にありません/, result.errors.join)
  end

  # 同じ科目が2つの経路にあるのは、便覧が「A＋B、または A＋C」と書いている形。画面では止めない。
  # 学生がその科目を修得したときに重複算入を確かめるのは判定の仕事で、OneOfPaths#mixed? が要確認にする。
  test '同じ科目を2つの経路に選べる(重複の判断は判定に任せる)' do
    result = save_paths('a' => { roles: %w[course_人101] }, 'b' => { roles: %w[course_人101 course_人103] })

    assert_predicate result, :ok?
    assert_equal [%w[role_a], %w[role_a course_人103]], rule_after('english_required')['paths']
  end

  # 画面は役割キーを出さないが、保存できなかった送信を戻すときは役割キーのまま返ってくる。
  test 'いままでどおり役割キーが送られても、そのまま通る' do
    result = save_paths('a' => { roles: %w[role_b] })

    assert_predicate result, :ok?
    assert_equal [%w[role_b]], rule_after('english_required')['paths']
  end

  test '科目を1つも選ばなかった経路は捨てる' do
    result = save_paths('a' => { roles: [''] }, 'b' => { roles: %w[course_人101] })

    assert_predicate result, :ok?
    assert_equal [%w[role_a]], rule_after('english_required')['paths']
  end

  test '触らずに保存しても、文書は1バイトも変わらない' do
    before = @curriculum.document.deep_dup

    save_paths('a' => { roles: %w[role_a] })

    assert_equal before, document_after
  end
end

