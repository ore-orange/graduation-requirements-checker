# frozen_string_literal: true

require 'json'

class CurriculumRepository
  class Error < StandardError; end
  class InvalidInput < Error; end
  class NotFound < Error; end
  class InvalidDocument < Error; end
  class ReadError < Error; end

  def self.find(department:, admission_year:)
    new.find(department: department, admission_year: admission_year)
  end

  def initialize(root: Rails.root.join('config/curricula'))
    @root = Pathname.new(root)
  end

  def find(department:, admission_year:)
    validate_input!(department, admission_year)
    path = @root.join(department, "#{admission_year}.json")
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

  private

  def validate_input!(department, admission_year)
    valid_department = department.is_a?(String) && department.match?(/\A[a-z][a-z0-9_]*\z/)
    valid_year = admission_year.is_a?(Integer) && (1..9999).cover?(admission_year)
    return if valid_department && valid_year

    raise InvalidInput, 'Use a department slug and an integer admission year (1..9999)'
  end

  def ensure_contained!(path)
    # 入力だけでなく、Git管理ディレクトリ内のsymlinkによる脱出も拒否する。
    return if path.realpath.to_s.start_with?("#{@root.realpath}#{File::SEPARATOR}")

    raise InvalidInput, 'Curriculum path is outside the configured directory'
  end
end

