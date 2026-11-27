# frozen_string_literal: true

require 'test_helper'

# 読み取りの窓口は偽物に差し替える。外部APIは呼ばない。
class ReadRequirementsPageTest < ActiveSupport::TestCase
  # 呼ばれた順に答えを返す。要素が例外なら投げる。
  class FakeReader
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
    end

    def read(image_path:, text:)
      @calls << { image_path: image_path.to_s, text: text }
      answer = @answers.shift
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  setup do
    @draft = Curriculum.create!(slug: 'test_program', admission_year: 2025, document: {}, pages: [
                                  { 'page' => 11, 'text' => '卒業要件', 'status' => 'pending', 'error' => nil },
                                  { 'page' => 12, 'text' => '', 'status' => 'pending', 'error' => nil }
                                ])
    [11, 12].each do |page|
      FileUtils.mkdir_p(@draft.images_dir)
      File.binwrite(@draft.images_dir.join("p#{page}.png"), 'png')
    end
  end

  def answer(category)
    { 'categories' => [{ 'key' => category, 'label' => category }], 'roles' => [], 'rules' => [],
      'display' => { 'total_credits' => nil, 'groups' => [] } }
  end

  def read(page, reader) = CurriculumImport::ReadRequirementsPage.call(@draft, page, reader: reader)

  test '読み取った結果を下書きに入れ、ページを読み取り済みにする' do
    reader = FakeReader.new(answer('health'))

    assert read(11, reader)

    @draft.reload
    assert_equal %w[health], @draft.document['categories'].pluck('key')
    assert_equal 'read', @draft.page_entry(11)['status']
    assert_equal %w[health], @draft.page_entry(11).dig('contributed', 'categories')
    assert_equal({ image_path: @draft.images_dir.join('p11.png').to_s, text: '卒業要件' }, reader.calls.first)
  end

  test '読み直すと、そのページが前に足したものを入れ替え、他のページの分は残す' do
    read(11, FakeReader.new(answer('health')))
    read(12, FakeReader.new(answer('social')))
    read(11, FakeReader.new(answer('humanities')))

    assert_equal %w[social humanities], @draft.reload.document['categories'].pluck('key')
  end

  test '読めなかったページは失敗にして理由を残し、前に読めていた分は消さない' do
    read(11, FakeReader.new(answer('health')))

    assert_not read(11, FakeReader.new(RequirementsReader::Error.new('HTTP 503')))

    @draft.reload
    assert_equal 'failed', @draft.page_entry(11)['status']
    assert_equal 'HTTP 503', @draft.page_entry(11)['error']
    assert_equal %w[health], @draft.document['categories'].pluck('key')
  end

  test 'ページ画像が無ければ、読みに行かずに失敗にする' do
    FileUtils.rm(@draft.images_dir.join('p12.png'))
    reader = FakeReader.new

    assert_not read(12, reader)
    assert_empty reader.calls
    assert_match '画像が見つかりません', @draft.reload.page_entry(12)['error']
  end

  test '公開済みの便覧や、下書きに無いページは読まない' do
    assert_raises(ArgumentError) { read(99, FakeReader.new) }

    @draft.update!(published_at: Time.current)
    assert_raises(ArgumentError) { read(11, FakeReader.new) }
  end
end

