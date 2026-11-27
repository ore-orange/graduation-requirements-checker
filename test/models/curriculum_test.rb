# frozen_string_literal: true

require 'test_helper'
# 便覧の初期データはseedの一部で、オートロードの対象外なので直接読む
require Rails.root.join('db/seeds/curricula')

class CurriculumTest < ActiveSupport::TestCase
  setup do
    @published = curricula(:intelligent_informatics2024)
  end

  def build(**attributes)
    Curriculum.new({ slug: 'test_program', admission_year: 2025, document: {} }.merge(attributes))
  end

  test '公開済みの便覧は slug と入学年度で引ける' do
    assert_equal @published, Curriculum.find_published(slug: 'intelligent_informatics', admission_year: 2024)
    assert_nil Curriculum.find_published(slug: 'intelligent_informatics', admission_year: 2030)
  end

  test '公開していない便覧は引かない' do
    @published.update!(published_at: nil)

    assert_nil Curriculum.find_published(slug: 'intelligent_informatics', admission_year: 2024)
    assert_empty Curriculum.published_years('intelligent_informatics')
  end

  test '公開済みの入学年度を古い順に返す' do
    build(slug: 'intelligent_informatics', admission_year: 2023, published_at: Time.current).save!
    build(slug: 'intelligent_informatics', admission_year: 2025).save!

    assert_equal [2023, 2024], Curriculum.published_years('intelligent_informatics')
  end

  test '同じ slug・入学年度の公開済みは1つだけ' do
    duplicate = build(slug: 'intelligent_informatics', admission_year: 2024, published_at: Time.current)

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
  end

  test '公開していない行は同じ slug・入学年度に何件でも作れる' do
    2.times { build(slug: 'intelligent_informatics', admission_year: 2024).save! }

    assert_equal 2, Curriculum.where(slug: 'intelligent_informatics', admission_year: 2024, published_at: nil).count
  end

  test 'slug は小文字英数字とアンダースコアだけ' do
    ['', 'Test', '1st', 'a-b', '../x'].each do |slug|
      assert_not build(slug: slug).valid?, slug
    end
  end

  test '入学年度は1〜9999の整数' do
    [0, 10_000, 2024.5].each do |year|
      assert_not build(admission_year: year).valid?, year.to_s
    end
  end

  test '文書はJSONのオブジェクトでなければならない' do
    curriculum = build(document: [])

    assert_not curriculum.valid?
    assert_includes curriculum.errors[:document], 'はJSONのオブジェクトにしてください'
  end

  test 'ファイルから公開済みの便覧を作る' do
    Dir.mktmpdir do |root|
      write(root, 'test_program/2025.json', { 'title' => 'テスト便覧', 'rules' => [] })

      CurriculumFiles.load!(root)

      curriculum = Curriculum.find_published(slug: 'test_program', admission_year: 2025)
      assert_equal 'テスト便覧', curriculum.title
      assert_equal({ 'title' => 'テスト便覧', 'rules' => [] }, curriculum.document)
    end
  end

  test 'ファイルを2回流しても増えず、既にある便覧は書き換えない' do
    Dir.mktmpdir do |root|
      write(root, 'intelligent_informatics/2024.json', { 'title' => 'ファイル側の古い内容' })

      assert_no_difference('Curriculum.count') { 2.times { CurriculumFiles.load!(root) } }
      assert_not_equal 'ファイル側の古い内容', @published.reload.title
    end
  end

  test '入学年度でないファイル名や読めないJSONは、パスを添えて止める' do
    Dir.mktmpdir do |root|
      write(root, 'test_program/latest.json', {})
      assert_match 'latest.json', assert_raises(ArgumentError) { CurriculumFiles.load!(root) }.message
    end

    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'test_program'))
      File.write(File.join(root, 'test_program/2025.json'), '{ broken')
      assert_match '2025.json', assert_raises(ArgumentError) { CurriculumFiles.load!(root) }.message
    end
  end

  test '同梱の便覧ファイルはすべて読み込める' do
    Curriculum.delete_all

    loaded = CurriculumFiles.load!

    assert_includes loaded.map { |curriculum| [curriculum.slug, curriculum.admission_year] },
                    ['intelligent_informatics', 2024]
  end

  private

  def write(root, relative, document)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(document))
  end
end

