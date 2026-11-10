# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class CurriculumRepositoryTest < ActiveSupport::TestCase
  INVALID_SLUGS = ['../test_curriculum', '/etc', 'test/curriculum', 'test\\curriculum', "test\0curriculum", '',
                   nil, 42, 'test.curriculum', 'Test', "test_curriculum\n"].freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir('curricula-test-'))
    @repository = CurriculumRepository.new(root: @root)
    @directory = @root.join('test_curriculum')
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
      CurriculumRepository.find(curriculum: 'unregistered_test_curriculum', admission_year: 2024)
    end
  end

  test 'missing curriculum or root is reported as not found' do
    assert_raises(CurriculumRepository::NotFound) { find_curriculum }
    assert_raises(CurriculumRepository::NotFound) do
      CurriculumRepository.new(root: @root.join('missing')).find(curriculum: 'test_curriculum', admission_year: 2024)
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

  test 'invalid curriculum and year inputs never become file paths' do
    INVALID_SLUGS.each do |curriculum|
      assert_raises(CurriculumRepository::InvalidInput) do
        @repository.find(curriculum: curriculum, admission_year: 2024)
      end
    end
    ['2024', '../2024', 0, -1, 10_000, 2024.0, nil].each do |year|
      assert_raises(CurriculumRepository::InvalidInput) do
        @repository.find(curriculum: 'test_curriculum', admission_year: year)
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

  test 'available years lists the registered admission years in order' do
    %w[2026.json 2024.json 2025.json].each { |name| @directory.join(name).write('{}') }

    assert_equal [2024, 2025, 2026], @repository.available_years(curriculum: 'test_curriculum')
  end

  test 'available years ignores names that are not a four digit year' do
    %w[2024.json draft.json 202.json 20245.json 2024.txt].each { |name| @directory.join(name).write('{}') }

    assert_equal [2024], @repository.available_years(curriculum: 'test_curriculum')
  end

  test 'available years is empty for a curriculum that has no directory' do
    assert_empty @repository.available_years(curriculum: 'unregistered_test_curriculum')
  end

  test 'available years rejects slugs that could escape the root' do
    INVALID_SLUGS.each do |curriculum|
      assert_raises(CurriculumRepository::InvalidInput) do
        @repository.available_years(curriculum: curriculum)
      end
    end
  end

  private

  def find_curriculum
    @repository.find(curriculum: 'test_curriculum', admission_year: 2024)
  end
end

