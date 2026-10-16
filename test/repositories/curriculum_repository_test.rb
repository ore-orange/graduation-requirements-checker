# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class CurriculumRepositoryTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir('curricula-test-'))
    @repository = CurriculumRepository.new(root: @root)
    @directory = @root.join('test_department')
    @directory.mkpath
    @path = @directory.join('2024.json')
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test 'reads a JSON object without exposing storage paths to callers' do
    # 人工データ。実際の大学の要件・分類は表現しない。
    document = { 'format_version' => 1, 'revision' => 'test', 'categories' => [] }
    @path.write(JSON.generate(document))
    assert_equal document, find_curriculum
  end

  test 'class interface reports that unregistered curricula are missing' do
    assert_raises(CurriculumRepository::NotFound) do
      CurriculumRepository.find(department: 'unregistered_test_department', admission_year: 2024)
    end
  end

  test 'missing curriculum or root is reported as not found' do
    assert_raises(CurriculumRepository::NotFound) { find_curriculum }
    assert_raises(CurriculumRepository::NotFound) do
      CurriculumRepository.new(root: @root.join('missing')).find(department: 'test_department', admission_year: 2024)
    end
  end

  test 'invalid JSON errors do not leak source text or parser causes' do
    @path.write('{secret test data')
    error = assert_raises(CurriculumRepository::InvalidDocument) { find_curriculum }
    assert_not_includes error.message, 'secret'
    assert_nil error.cause
  end

  test 'top level JSON must be an object' do
    ['[]', 'null', '1', '"string"'].each do |json|
      @path.write(json)
      assert_raises(CurriculumRepository::InvalidDocument) { find_curriculum }
    end
  end

  test 'invalid department and year inputs never become file paths' do
    ['../test_department', '/etc', 'test/department', 'test\\department', "test\0department", '', nil, 42,
     'test.department', 'Test', "test_department\n"].each do |department|
      assert_raises(CurriculumRepository::InvalidInput) do
        @repository.find(department: department, admission_year: 2024)
      end
    end
    ['2024', '../2024', 0, -1, 10_000, 2024.0, nil].each do |year|
      assert_raises(CurriculumRepository::InvalidInput) do
        @repository.find(department: 'test_department', admission_year: year)
      end
    end
  end

  test 'symlinks cannot escape the configured root' do
    Dir.mktmpdir('outside-curricula-') do |outside|
      outside_path = Pathname.new(outside).join('2024.json')
      outside_path.write('{}')
      File.symlink(outside_path, @path)
      assert_raises(CurriculumRepository::InvalidInput) { find_curriculum }
    end
  end

  test 'a directory in place of a JSON file is a read error' do
    @path.mkpath
    assert_raises(CurriculumRepository::ReadError) { find_curriculum }
  end

  private

  def find_curriculum
    @repository.find(department: 'test_department', admission_year: 2024)
  end
end

