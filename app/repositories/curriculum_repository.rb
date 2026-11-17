# frozen_string_literal: true

require 'json'

class CurriculumRepository
  class Error < StandardError; end
  class InvalidInput < Error; end
  class NotFound < Error; end
  class InvalidDocument < Error; end
  class ReadError < Error; end

  def self.find(curriculum:, admission_year:)
    new.find(curriculum: curriculum, admission_year: admission_year)
  end

  def self.available_years(curriculum:)
    new.available_years(curriculum: curriculum)
  end

  def initialize(root: Rails.root.join('config/curricula'))
    @root = Pathname.new(root)
  end

  def find(curriculum:, admission_year:)
    validate_curriculum!(curriculum)
    validate_admission_year!(admission_year)
    path = @root.join(curriculum, "#{admission_year}.json")
    ensure_contained!(path)
    document = JSON.parse(path.read)
    raise InvalidDocument, 'Curriculum must be a JSON object' unless document.is_a?(Hash)

    document
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise NotFound, 'Curriculum not found', cause: nil
  rescue JSON::ParserError
    # パーサーのメッセージにはファイル本文が含まれ得るため、外には出さない。
    raise InvalidDocument, 'Curriculum contains invalid JSON', cause: nil
  rescue SystemCallError, IOError
    raise ReadError, 'Curriculum could not be read', cause: nil
  end

  # 用意されている入学年度。ファイル名がそのまま年度なので、4桁の数字だけを拾う。
  # 中身は読まないため、ここでは存在しないディレクトリも空として扱う。
  def available_years(curriculum:)
    validate_curriculum!(curriculum)
    @root.join(curriculum).glob('*.json')
         .map { |path| path.basename('.json').to_s }
         .grep(/\A\d{4}\z/)
         .map(&:to_i)
         .sort
  end

  private

  def validate_curriculum!(curriculum)
    return if curriculum.is_a?(String) && curriculum.match?(/\A[a-z][a-z0-9_]*\z/)

    raise InvalidInput, 'Use a curriculum slug'
  end

  def validate_admission_year!(admission_year)
    return if admission_year.is_a?(Integer) && (1..9999).cover?(admission_year)

    raise InvalidInput, 'Use an integer admission year (1..9999)'
  end

  def ensure_contained!(path)
    # 入力だけでなく、Git管理ディレクトリ内のsymlinkによる脱出も拒否する。
    return if path.realpath.to_s.start_with?("#{@root.realpath}#{File::SEPARATOR}")

    raise InvalidInput, 'Curriculum path is outside the configured directory'
  end
end

