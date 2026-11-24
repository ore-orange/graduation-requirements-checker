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
    assert_empty result['warnings']
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

  test '形の違う規則だけを外して警告にし、ほかの規則は取り込む' do
    broken = { 'id' => 'Fusion Rule', 'type' => 'grouped_max', 'label' => '工学融合', 'category' => 'fusion',
               'required_credits' => 4 }

    result = read(VALID.merge('rules' => VALID['rules'] + [broken]))

    assert_equal %w[health], result['rules'].pluck('id')
    assert_equal 1, result['warnings'].size
    assert_equal '「工学融合」は、条件の中身が読み取れなかったため、取り込んでいません。PDFで確認してください。',
                 result['warnings'].first
  end

  test '入れ子の条件の欄も確かめる' do
    rule = { 'id' => 'foreign', 'type' => 'any_of', 'label' => '外国語',
             'options' => [{ 'type' => 'all_of', 'conditions' => [{ 'type' => 'credit_sum', 'categories' => [] }] }] }

    result = read(VALID.merge('rules' => [rule]))

    assert_empty result['rules']
    assert_equal '「外国語」は、どの科目区分を数えるのかが読み取れなかったため、取り込んでいません。PDFで確認してください。',
                 result['warnings'].first
  end

  test '複数の区分をまとめた exclude は区分ごとに分け、理由が無ければ見出しを理由にする' do
    rule = { 'id' => 'not_counted', 'type' => 'exclude', 'label' => '卒業要件に含めない',
             'categories' => %w[data_literacy global] }

    result = read(VALID.merge('rules' => [rule]))

    assert_equal [{ 'id' => 'not_counted_1', 'type' => 'exclude', 'label' => '卒業要件に含めない',
                    'category' => 'data_literacy', 'reason' => '卒業要件に含めない' },
                  { 'id' => 'not_counted_2', 'type' => 'exclude', 'label' => '卒業要件に含めない',
                    'category' => 'global', 'reason' => '卒業要件に含めない' }], result['rules']
    assert_empty result['warnings']
  end

  test '答えがオブジェクトでなければ、読み取りの失敗にする' do
    assert_raises(RequirementsReader::Error) { read(['規則']) }
  end

  test 'Gemini を呼べなかったときは、理由に合った分かる言葉で伝える(状態コードは出さない)' do
    busy = assert_raises(RequirementsReader::Error) do
      read(GeminiClient::Error.new('HTTP 503 UNAVAILABLE', reason: :busy))
    end
    setup = assert_raises(RequirementsReader::Error) do
      read(GeminiClient::Error.new('HTTP 403 PERMISSION_DENIED', reason: :setup))
    end

    assert_match 'AIが混み合っていて', busy.message
    assert_no_match '503', busy.message
    assert_match '管理担当者に連絡', setup.message
  end

  test '区分が1つだけの credit_sum を category で返されても、categories にそろえて受け入れる' do
    rule = { 'id' => 'foreign', 'type' => 'any_of', 'label' => '外国語', 'options' => [
      { 'type' => 'all_of',
        'conditions' => [{ 'type' => 'credit_sum', 'category' => 'first', 'required_credits' => 8 }] },
      { 'type' => 'credit_sum', 'category' => 'first', 'required_credits' => 12 }
    ] }

    result = read(VALID.merge('rules' => [rule]))

    options = result['rules'].first['options']
    assert_equal({ 'type' => 'credit_sum', 'categories' => ['first'], 'required_credits' => 8 },
                 options.first['conditions'].first)
    assert_equal({ 'type' => 'credit_sum', 'categories' => ['first'], 'required_credits' => 12 }, options.last)
  end
end

