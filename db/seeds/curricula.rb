# frozen_string_literal: true

require 'json'

# config/curricula/<slug>/<入学年度>.json を、公開済みの便覧としてDBに入れる。何度流しても増えない。
#
# 同じ slug・入学年度の公開済みが既にあれば、その行には触れない。ファイルは初回の種にすぎず、
# 入ったあとはDBが正本になる(あとで管理者が画面から直した便覧を、ファイルの古い内容に戻さないため)。
# ファイルを直してDBに反映したいときは、該当の行を消してから流し直す。
module CurriculumFiles
  ROOT = Rails.root.join('config/curricula')

  def self.load!(root = ROOT)
    Pathname.new(root).glob('*/*.json').sort.map { |path| load_file!(path) }
  end

  def self.load_file!(path)
    slug = path.dirname.basename.to_s
    admission_year = admission_year_of(path)
    existing = Curriculum.find_published(slug: slug, admission_year: admission_year)
    return existing if existing

    document = parse(path)
    Curriculum.create!(slug: slug, admission_year: admission_year, title: document['title'],
                       document: document, published_at: Time.current)
  end

  # どのファイルが悪いか分かるように、例外にはパスを入れる。
  def self.admission_year_of(path)
    Integer(path.basename('.json').to_s, 10)
  rescue ArgumentError
    raise ArgumentError, "便覧のファイル名は入学年度(例: 2024.json)にしてください: #{path}"
  end

  def self.parse(path)
    JSON.parse(path.read)
  rescue JSON::ParserError
    # パーサーのメッセージには本文が含まれ得るので、パスだけを出す。
    raise ArgumentError, "便覧のJSONを読めません: #{path}"
  end
  private_class_method :load_file!, :admission_year_of, :parse
end

