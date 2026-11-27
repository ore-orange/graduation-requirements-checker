# frozen_string_literal: true

require 'test_helper'

# 外部APIは呼ばない。通信(transport)を偽物に差し替えて、送る中身と、答え・失敗の扱いを見る。
class GeminiClientTest < ActiveSupport::TestCase
  API_KEY = 'test-api-key-should-not-leak'
  SCHEMA = { type: 'object', properties: { title: { type: 'string' } }, required: %w[title] }.freeze

  # 呼ばれた順に responses を返し、送られたものを requests に残す。要素が例外なら投げる。
  class FakeTransport
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def call(uri, headers, body)
      @requests << { uri: uri, headers: headers, body: JSON.parse(body) }
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  def answer(json, finish: 'STOP')
    [200, JSON.generate(candidates: [{ content: { parts: [{ text: json }] }, finishReason: finish }]), {}]
  end

  def client(transport)
    @waits = []
    GeminiClient.new(api_key: API_KEY, model: 'gemini-test', transport: transport,
                     sleeper: ->(seconds) { @waits << seconds })
  end

  def generate(transport, **)
    client(transport).generate_json(prompt: '表を読んでください', schema: SCHEMA, **)
  end

  test '答えのJSONをHashで返す' do
    transport = FakeTransport.new(answer('{"title":"便覧"}'))

    assert_equal({ 'title' => '便覧' }, generate(transport))
  end

  test 'APIキーはヘッダにだけ入れ、スキーマの型名は大文字にして送る' do
    transport = FakeTransport.new(answer('{"title":"便覧"}'))
    generate(transport)

    request = transport.requests.first
    assert_equal API_KEY, request[:headers]['x-goog-api-key']
    assert_not_includes request[:uri].to_s, API_KEY
    assert_equal "#{GeminiClient::ENDPOINT}/gemini-test:generateContent", request[:uri].to_s
    config = request[:body]['generationConfig']
    assert_equal 'application/json', config['responseMimeType']
    assert_equal 'OBJECT', config['responseSchema']['type']
    assert_equal 'STRING', config.dig('responseSchema', 'properties', 'title', 'type')
    assert_equal [{ 'text' => '表を読んでください' }], request[:body].dig('contents', 0, 'parts')
  end

  test '画像を渡すと、依頼文と一緒に送る' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'p1.png')
      File.binwrite(path, 'png-bytes')
      transport = FakeTransport.new(answer('{"title":"便覧"}'))

      generate(transport, image_path: path)

      image = transport.requests.first[:body].dig('contents', 0, 'parts', 1, 'inlineData')
      assert_equal({ 'mimeType' => 'image/png', 'data' => Base64.strict_encode64('png-bytes') }, image)
    end
  end

  test 'PNG・JPEG 以外の画像や、読めない画像は送らない' do
    transport = FakeTransport.new

    assert_raises(GeminiClient::Error) { generate(transport, image_path: 'page.gif') }
    assert_raises(GeminiClient::Error) { generate(transport, image_path: '/nonexistent/p1.png') }
    assert_empty transport.requests
  end

  test 'APIキーが無ければ呼ばない' do
    transport = FakeTransport.new
    gemini = GeminiClient.new(api_key: '', transport: transport)

    assert_raises(GeminiClient::Error) { gemini.generate_json(prompt: 'x', schema: SCHEMA) }
    assert_empty transport.requests
  end

  test 'モデル名に使えない文字があれば作れない' do
    assert_raises(ArgumentError) { GeminiClient.new(api_key: API_KEY, model: '../models') }
  end

  test '429 は Retry-After の秒数だけ待ってやり直す' do
    transport = FakeTransport.new([429, '{}', { 'retry-after' => '7' }], answer('{"title":"便覧"}'))

    assert_equal({ 'title' => '便覧' }, generate(transport))
    assert_equal [7], @waits
  end

  test '5xx と通信の失敗は、待ちを倍々にして3回まで試す' do
    transport = FakeTransport.new([503, '{}', {}], Errno::ECONNRESET.new, [500, '{}', {}])

    error = assert_raises(GeminiClient::Error) { generate(transport) }
    assert_match '3回試しました', error.message
    assert_equal [4, 8], @waits
  end

  test 'Retry-After が大きすぎても、待ちは上限で止める' do
    transport = FakeTransport.new([429, '{}', { 'retry-after' => '99999' }], answer('{"title":"便覧"}'))
    generate(transport)

    assert_equal [GeminiClient::MAX_RETRY_AFTER], @waits
  end

  test '400番台(429以外)はやり直さず、状態名だけを伝える' do
    body = JSON.generate(error: { status: 'PERMISSION_DENIED', message: "key #{API_KEY} is invalid" })
    transport = FakeTransport.new([403, body, {}])

    error = assert_raises(GeminiClient::Error) { generate(transport) }
    assert_equal 1, transport.requests.size
    assert_match 'HTTP 403 PERMISSION_DENIED', error.message
    assert_not_includes error.message, API_KEY
  end

  test '答えが途中で止まったものは使わない' do
    transport = FakeTransport.new(answer('{"title":', finish: 'MAX_TOKENS'))

    error = assert_raises(GeminiClient::Error) { generate(transport) }
    assert_match 'MAX_TOKENS', error.message
  end

  test '答えが無い・JSONでない・オブジェクトでないものは使わない' do
    blocked = [200, JSON.generate(promptFeedback: { blockReason: 'SAFETY' }), {}]
    assert_match 'SAFETY', assert_raises(GeminiClient::Error) { generate(FakeTransport.new(blocked)) }.message

    assert_raises(GeminiClient::Error) { generate(FakeTransport.new(answer('読めませんでした'))) }
    assert_raises(GeminiClient::Error) { generate(FakeTransport.new(answer('["便覧"]'))) }
    assert_raises(GeminiClient::Error) { generate(FakeTransport.new([200, 'not json', {}])) }
  end

  test '考えの断片(thought)は答えに混ぜない' do
    parts = [{ text: '考え中', thought: true }, { text: '{"title":"便覧"}' }]
    response = [200, JSON.generate(candidates: [{ content: { parts: parts }, finishReason: 'STOP' }]), {}]

    assert_equal({ 'title' => '便覧' }, generate(FakeTransport.new(response)))
  end

  test 'APIキーが環境変数にあるときだけ使える' do
    original = ENV.fetch(GeminiClient::API_KEY_ENV, nil)
    ENV[GeminiClient::API_KEY_ENV] = ''
    assert_not GeminiClient.available?

    ENV[GeminiClient::API_KEY_ENV] = 'set'
    assert_predicate GeminiClient, :available?
  ensure
    ENV[GeminiClient::API_KEY_ENV] = original
  end
end

