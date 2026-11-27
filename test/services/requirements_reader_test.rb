# frozen_string_literal: true

require 'test_helper'

# Gemini は呼ばない。GeminiClient を偽物に差し替えて、依頼の中身と、答えの確かめ方を見る。
class RequirementsReaderTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :request

    def initialize(answer)
      @answer = answer
    end

    def generate_json(prompt:, schema:, image_path:)
      @request = { prompt: prompt, schema: schema, image_path: image_path }
      raise @answer if @answer.is_a?(Exception)

      @answer
    end
  end

  VALID = {
    'categories' => [{ 'key' => 'health', 'label' => '健康運動系科目' }],
    'roles' => [{ 'key' => 'physics_1', 'label' => '物理学Ⅰ' }],
    'rules' => [{ 'id' => 'health', 'type' => 'credit_sum', 'label' => '健康運動系', 'detail' => nil,
                  'categories' => ['health'], 'required_credits' => 2, 'category' => nil, 'options' => nil }],
    'display' => { 'total_credits' => 130, 'groups' => [] }
  }.freeze

  def read(answer, text: '卒業要件')
    @client = FakeClient.new(answer)
    RequirementsReader.new(client: @client).read(image_path: 'p11.png', text: text)
  end

  test '答えを下書きに入れる形に整える(書かれていない欄を落とす)' do
    result = read(VALID)

    assert_equal({ 'id' => 'health', 'type' => 'credit_sum', 'label' => '健康運動系', 'categories' => ['health'],
                   'required_credits' => 2 }, result['rules'].first)
    assert_equal VALID['categories'], result['categories']
    assert_equal 'p11.png', @client.request[:image_path]
  end

  test '依頼文にページの文字を付け、文字が無いときは画像だけで読むよう伝える' do
    read(VALID, text: '健康運動系科目 2単位以上')
    assert_includes @client.request[:prompt], '健康運動系科目 2単位以上'

    read(VALID, text: "  \n")
    assert_includes @client.request[:prompt], '画像だけで読むこと'
  end

  test '答えの形のスキーマは、規則の型を判定が読めるものに限る' do
    read(VALID)
    rule_types = @client.request[:schema].dig(:properties, :rules, :items, :properties, :type, :enum)

    assert_equal %w[credit_sum grouped_max one_of_paths all_required any_of cap exclude], rule_types
    assert(rule_types.all? { |type| GraduationAssessment::Rules::CONDITIONS.key?(type) || type.in?(%w[cap exclude]) })
  end

  test '型ごとに要る欄が無い・識別子の書き方が違う答えは、読み取りの失敗にする' do
    broken = VALID.merge('rules' => [{ 'id' => 'Fusion Rule', 'type' => 'grouped_max', 'label' => '工学融合',
                                       'category' => 'fusion', 'required_credits' => 4 }])

    error = assert_raises(RequirementsReader::Error) { read(broken) }
    assert_match 'Fusion Rule', error.message
    assert_match 'group_by が無い', error.message
  end

  test '入れ子の条件の欄も確かめる' do
    rule = { 'id' => 'foreign', 'type' => 'any_of', 'label' => '外国語',
             'options' => [{ 'type' => 'all_of', 'conditions' => [{ 'type' => 'credit_sum', 'categories' => [] }] }] }

    error = assert_raises(RequirementsReader::Error) { read(VALID.merge('rules' => [rule])) }
    assert_match 'foreign の中の all_of の中の credit_sum の categories が無い', error.message
  end

  test 'Gemini を呼べなかったときは、読み取りの失敗として理由を伝える' do
    error = assert_raises(RequirementsReader::Error) { read(GeminiClient::Error.new('HTTP 503 UNAVAILABLE')) }

    assert_equal 'HTTP 503 UNAVAILABLE', error.message
  end
end

