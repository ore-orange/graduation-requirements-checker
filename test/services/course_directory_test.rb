# frozen_string_literal: true

require 'test_helper'

class CourseDirectoryTest < ActiveSupport::TestCase
  def document(courses: [], categories: nil)
    {
      'categories' => categories || [
        { 'key' => 'ge_humanities', 'number_patterns' => %w[人文 総合1] },
        { 'key' => 'foreign', 'number_patterns' => ['外1'] }
      ],
      'courses' => courses
    }
  end

  def registered(number, **attrs)
    { 'number' => number, 'name' => "登録#{number}", 'credits' => 4, 'category' => 'special',
      'required' => true, 'roles' => ['basic'], 'requires_approval' => true, 'selectable' => false }.merge(attrs)
  end

  test '便覧に登録された科目は、登録の区分・必修・役割・承認・選べるかを持つ' do
    Course.create!(course_number: '知能101', name: '知能入門', credits: 2)
    entry = CourseDirectory.new(document(courses: [registered('知能101')])).in_category('special').sole

    assert_equal 'special', entry.category
    assert_equal true, entry.required
    assert_equal ['basic'], entry.roles
    assert_equal true, entry.requires_approval
    assert_equal false, entry.selectable
  end

  test '登録された科目の名前と単位は、Course の行があればそちらを使う' do
    course = Course.create!(course_number: '知能101', name: '知能入門', credits: 2)
    entry = CourseDirectory.new(document(courses: [registered('知能101')])).find(course.id)

    assert_equal '知能入門', entry.name
    assert_equal 2, entry.credits
    assert_equal course.id, entry.course_id
    assert_equal '知能101', entry.number
  end

  test '登録の名前と単位は、Course の値が空のときに使う' do
    course = Course.create!(course_number: '知能101', name: '知能入門', credits: nil)
    entry = CourseDirectory.new(document(courses: [registered('知能101')])).find(course.id)

    assert_equal 4, entry.credits
  end

  test '登録が無い Course は、番号パターンで区分が決まれば名簿に出る' do
    course = Course.create!(course_number: '人文101', name: '哲学', credits: 2)
    directory = CourseDirectory.new(document)

    assert_equal [course.id], directory.in_category('ge_humanities').map(&:course_id)
    assert_equal 'ge_humanities', directory.category_for('人文101')
    assert_equal ['ge_humanities'], directory.categories
  end

  test 'パターンで出た科目は、必修でも役割持ちでも承認要でもなく、選べる' do
    Course.create!(course_number: '人文101', name: '哲学', credits: 2)
    entry = CourseDirectory.new(document).in_category('ge_humanities').sole

    assert_equal false, entry.required
    assert_equal [], entry.roles
    assert_equal false, entry.requires_approval
    assert_equal true, entry.selectable
  end

  test '番号パターンで区分が決まらない Course は、名簿に出ない' do
    Course.create!(course_number: '知能999', name: '不明', credits: 2)
    directory = CourseDirectory.new(document)

    assert_equal [], directory.categories
    assert_nil directory.category_for('知能999')
  end

  test '科目番号の無い Course は、名簿に出ない' do
    Course.create!(course_number: nil, name: '番号なし')
    Course.create!(course_number: '', name: '空番号')

    assert_equal [], CourseDirectory.new(document).categories
  end

  test '学生の自由入力で作られた Course(custom_category あり)は、名簿に出ない' do
    Course.create!(course_number: '人文101', name: '自由入力', custom_category: 'ge_humanities')

    assert_equal [], CourseDirectory.new(document).in_category('ge_humanities')
  end

  test '同じ番号で名前の違う Course が2行あれば、2件とも出る' do
    a = Course.create!(course_number: '人文101', name: '哲学A', credits: 2)
    b = Course.create!(course_number: '人文101', name: '哲学B', credits: 2)
    entries = CourseDirectory.new(document).in_category('ge_humanities')

    assert_equal [a.id, b.id].sort, entries.map(&:course_id).sort
    assert_equal %w[哲学A 哲学B], entries.map(&:name).sort
  end

  test 'categories が空の文書では、どの区分も空を返す' do
    Course.create!(course_number: '人文101', name: '哲学', credits: 2)
    [{ 'categories' => [], 'courses' => [] }, {}, nil].each do |doc|
      directory = CourseDirectory.new(doc)

      assert_equal [], directory.in_category('ge_humanities')
      assert_equal [], directory.categories
      assert_nil directory.category_for('人文101')
    end
  end

  test 'in_category は番号順に返す' do
    Course.create!(course_number: '人文203', name: 'C')
    Course.create!(course_number: '人文101', name: 'A')
    Course.create!(course_number: '人文102', name: 'B')

    assert_equal %w[人文101 人文102 人文203], CourseDirectory.new(document).in_category('ge_humanities').map(&:number)
  end

  test 'find は Course の id から1件を返す' do
    course = Course.create!(course_number: '外101', name: '英語')
    directory = CourseDirectory.new(document)

    assert_equal '英語', directory.find(course.id).name
    assert_nil directory.find(0)
  end

  test 'Course は1つのインスタンスの中で1回しか引かない' do
    Course.create!(course_number: '人文101', name: '哲学')
    directory = CourseDirectory.new(document)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('"courses"') }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      directory.in_category('ge_humanities')
      directory.categories
      directory.category_for('人文101')
      directory.find(1)
    end

    assert_equal 1, queries.size
  end
end

