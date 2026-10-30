# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class CurriculumReaderGeminiTest < ActiveSupport::TestCase
  KEY = 'test-key-not-real-0123'
  SCHEMA = { type: 'object', properties: { type: { type: 'string', nullable: true }, n: { type: 'number' } },
             required: ['n'] }.freeze

  # 偽の通信。呼ばれた内容を覚え、決めた [状態, 本文] を返す。
  class Transport
    attr_reader :uri, :headers, :body

    def initialize(*responses)
      @responses = responses
    end

    def call(uri, headers, body)
      @uri = uri
      @headers = headers
      @body = body
      response = @responses.size > 1 ? @responses.shift : @responses.first
      raise response if response.is_a?(Exception)

      response
    end

    def sent = JSON.parse(body)
  end

  def ok_body(text, finish: 'STOP')
    JSON.generate('candidates' => [{ 'content' => { 'parts' => [{ 'text' => text }] }, 'finishReason' => finish }])
  end

  def gemini(transport, **)
    CurriculumReader::Gemini.new(api_key: KEY, transport: transport, **)
  end

  def generate(transport, image_path: nil, **)
    gemini(transport, **).generate(prompt: 'P', image_path: image_path, schema: SCHEMA)
  end

  def png
    path = File.join(scratch_dir, 'page.png')
    File.binwrite(path, "\x89PNG\r\n\x1a\nfake".b)
    path
  end

  # 並列の実行どうしで消し合わないよう、テストごとに別の場所に書く。
  def scratch_dir
    @scratch_dir ||= Dir.mktmpdir('gemini_test')
  end

  setup do
    # どのテストも実通信に出ない。偽の通信を差し替え忘れたら、ここで落ちる。
    @original_start = Net::HTTP.method(:start)
    Net::HTTP.singleton_class.send(:define_method, :start) { |*| raise 'テストが実際の通信に出ようとした' }
  end

  teardown do
    original = @original_start
    Net::HTTP.singleton_class.send(:define_method, :start) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
    FileUtils.rm_rf(@scratch_dir) if @scratch_dir
  end

  test '答えのJSONをHashにして返す' do
    assert_equal({ 'n' => 1 }, generate(Transport.new([200, ok_body('{"n":1}')])))
  end

  test 'キーはヘッダに入れ、URLにもボディにも入れない' do
    transport = Transport.new([200, ok_body('{"n":1}')])
    generate(transport)

    assert_equal KEY, transport.headers['x-goog-api-key']
    assert_not_includes transport.uri.to_s, KEY
    assert_not_includes transport.body, KEY
    assert_equal 'generativelanguage.googleapis.com', transport.uri.host
    assert_predicate transport.uri, :scheme
    assert_equal 'https', transport.uri.scheme
    assert transport.uri.path.end_with?(':generateContent')
  end

  test 'プロンプトとスキーマを送り、答えをJSONに縛る(型の名前はGeminiの綴りに直す)' do
    transport = Transport.new([200, ok_body('{"n":1}')])
    generate(transport)
    sent = transport.sent

    assert_equal 'P', sent.dig('contents', 0, 'parts', 0, 'text')
    assert_equal 'application/json', sent.dig('generationConfig', 'responseMimeType')
    schema = sent.dig('generationConfig', 'responseSchema')
    assert_equal 'OBJECT', schema['type']
    assert_equal 'NUMBER', schema.dig('properties', 'n', 'type')
    assert_equal({ 'type' => 'STRING', 'nullable' => true }, schema.dig('properties', 'type'),
                 '欄の名前が type のときも、その欄を壊さない')
    assert_equal ['n'], schema['required']
  end

  test '画像はbase64のinlineDataで、プロンプトの後ろに付ける' do
    transport = Transport.new([200, ok_body('{"n":1}')])
    generate(transport, image_path: png)
    parts = transport.sent.dig('contents', 0, 'parts')

    assert_equal 2, parts.size
    assert_equal 'image/png', parts[1].dig('inlineData', 'mimeType')
    assert_equal "\x89PNG\r\n\x1a\nfake".b, Base64.strict_decode64(parts[1].dig('inlineData', 'data'))
  end

  test '画像がなければテキストだけを送る' do
    transport = Transport.new([200, ok_body('{"n":1}')])
    generate(transport)

    assert_equal 1, transport.sent.dig('contents', 0, 'parts').size
  end

  test '画像が読めなければ Error' do
    assert_raises(CurriculumReader::Error) { generate(Transport.new([200, ok_body('{}')]), image_path: '/no/such.png') }
  end

  test '画像でない拡張子は Error(送らない)' do
    path = File.join(scratch_dir, 'page.txt')
    File.write(path, 'x')
    transport = Transport.new([200, ok_body('{}')])

    assert_raises(CurriculumReader::Error) { generate(transport, image_path: path) }
    assert_nil transport.body
  end

  test 'キーが無ければ、通信せずに Error' do
    transport = Transport.new([200, ok_body('{}')])

    assert_raises(CurriculumReader::Error) do
      CurriculumReader::Gemini.new(api_key: nil, transport: transport)
                              .generate(prompt: 'P', image_path: nil, schema: SCHEMA)
    end
    assert_nil transport.body
  end

  test '429 と 5xx は状態コード付きの RequestFailed(窓口が再試行を決める)' do
    [429, 500, 503].each do |status|
      error = assert_raises(CurriculumReader::RequestFailed) { generate(Transport.new([status, '{}'])) }
      assert_equal status, error.status
    end
  end

  test '4xx は RequestFailed。Googleの状態名は載せ、本文の文章は載せない' do
    body = JSON.generate('error' => { 'status' => 'PERMISSION_DENIED', 'message' => "key #{KEY} is bad" })
    error = assert_raises(CurriculumReader::RequestFailed) { generate(Transport.new([403, body])) }

    assert_equal 403, error.status
    assert_includes error.message, 'PERMISSION_DENIED'
    assert_not_includes error.message, KEY
  end

  def failed_with(headers)
    assert_raises(CurriculumReader::RequestFailed) { generate(Transport.new([429, '{}', headers])) }
  end

  test '429 の Retry-After(秒数)を RequestFailed に載せる' do
    assert_equal 37, failed_with('retry-after' => '37').retry_after
    assert_equal 5, failed_with('retry-after' => ' 5 ').retry_after
  end

  test 'Retry-After が日時のときは、いまからの秒数にする' do
    header = (Time.current + 30).httpdate
    seconds = failed_with('retry-after' => header).retry_after

    assert_includes 28..31, seconds
    assert_equal 0, failed_with('retry-after' => (Time.current - 3600).httpdate).retry_after
  end

  test 'Retry-After が無い・読めない・負のときは nil(窓口の既定の待ちを使う)' do
    assert_nil failed_with({}).retry_after
    assert_nil failed_with('retry-after' => 'soon').retry_after
    assert_nil failed_with('retry-after' => '-5').retry_after
    assert_nil failed_with('retry-after' => '').retry_after
    assert_nil generate_failure_without_headers.retry_after
  end

  def generate_failure_without_headers
    assert_raises(CurriculumReader::RequestFailed) { generate(Transport.new([429, '{}'])) }
  end

  test '200 でも本文がJSONでなければ Error(RequestFailed ではない。再試行しない)' do
    error = assert_raises(CurriculumReader::Error) { generate(Transport.new([200, '<html>busy</html>'])) }

    assert_not_kind_of CurriculumReader::RequestFailed, error
    assert_not_includes error.message, 'busy'
  end

  test '候補が無い答え(安全性による遮断など)は Error' do
    body = JSON.generate('promptFeedback' => { 'blockReason' => 'SAFETY' })
    error = assert_raises(CurriculumReader::Error) { generate(Transport.new([200, body])) }

    assert_includes error.message, 'SAFETY'
  end

  test '途中で打ち切られた答え(MAX_TOKENS)は、JSONとして読めても Error' do
    error = assert_raises(CurriculumReader::Error) { generate(Transport.new([200, ok_body('{"n":1}', finish: 'MAX_TOKENS')])) }

    assert_includes error.message, 'MAX_TOKENS'
  end

  test '答えの文章がJSONでなければ Error' do
    assert_raises(CurriculumReader::Error) { generate(Transport.new([200, ok_body('申し訳ありません')])) }
  end

  test '答えがオブジェクトでなければ Error' do
    assert_raises(CurriculumReader::Error) { generate(Transport.new([200, ok_body('[1,2]')])) }
  end

  test '考えの断片(thought)は答えに混ぜない' do
    body = JSON.generate('candidates' => [{ 'finishReason' => 'STOP',
                                            'content' => { 'parts' => [{ 'text' => '考え中…', 'thought' => true },
                                                                       { 'text' => '{"n":2}' }] } }])

    assert_equal({ 'n' => 2 }, generate(Transport.new([200, body])))
  end

  test 'モデル名は環境変数で替えられ、URLに入れられない文字は拒む' do
    transport = Transport.new([200, ok_body('{"n":1}')])
    generate(transport, model: 'gemini-test-model')
    assert_includes transport.uri.path, 'models/gemini-test-model:generateContent'

    assert_raises(ArgumentError) { CurriculumReader::Gemini.new(api_key: KEY, model: '../x?key=1') }
  end

  # --- 既定の通信(Net::HTTP)。Net::HTTP.start だけを偽物にして、組み立てを確かめる。

  class FakeResponse
    attr_reader :code, :body

    def initialize(code, body, headers = {})
      @code = code
      @body = body
      @headers = headers
    end

    def [](name) = @headers[name.downcase]
  end

  class FakeHttp
    attr_reader :sent_request

    def initialize(response)
      @response = response
    end

    def request(request)
      @sent_request = request
      raise @response if @response.is_a?(Exception)

      @response
    end
  end

  def with_net_http(response)
    fake = FakeHttp.new(response)
    captured = {}
    starter = ->(host, port, **options, &block) do
      captured.merge!(host: host, port: port, options: options)
      block.call(fake)
    end
    Net::HTTP.stub(:start, starter) { yield fake, captured }
  end

  test '既定の通信は https で、時間を決めて呼ぶ。キーはヘッダにだけ入る' do
    with_net_http(FakeResponse.new('200', ok_body('{"n":1}').b)) do |fake, captured|
      result = CurriculumReader::Gemini.new(api_key: KEY).generate(prompt: 'P', image_path: nil, schema: SCHEMA)

      assert_equal({ 'n' => 1 }, result)
      assert_equal 'generativelanguage.googleapis.com', captured[:host]
      assert_equal 443, captured[:port]
      assert captured[:options][:use_ssl]
      assert_operator captured[:options][:read_timeout], :>, 0
      assert_operator captured[:options][:open_timeout], :>, 0
      assert_equal KEY, fake.sent_request['x-goog-api-key']
      assert_equal 'application/json', fake.sent_request['content-type']
      assert_not_includes fake.sent_request.path, KEY
    end
  end

  test '既定の通信は、応答の Retry-After を窓口に渡す' do
    with_net_http(FakeResponse.new('429', '{}', 'retry-after' => '42')) do
      error = assert_raises(CurriculumReader::RequestFailed) do
        CurriculumReader::Gemini.new(api_key: KEY).generate(prompt: 'P', image_path: nil, schema: SCHEMA)
      end

      assert_equal 429, error.status
      assert_equal 42, error.retry_after
    end
  end

  test '既定の通信で時間切れや接続失敗になったら、RequestFailed(状態コードなし。キーは載せない)' do
    [Net::ReadTimeout, Errno::ECONNRESET, SocketError, EOFError, OpenSSL::SSL::SSLError].each do |klass|
      with_net_http(klass.new("#{KEY} host")) do
        error = assert_raises(CurriculumReader::RequestFailed) do
          CurriculumReader::Gemini.new(api_key: KEY).generate(prompt: 'P', image_path: nil, schema: SCHEMA)
        end

        assert_nil error.status
        assert_includes error.message, klass.name
        assert_not_includes error.message, KEY
      end
    end
  end

  test '実通信に出る経路は、テストの中では塞がれている' do
    assert_raises(RuntimeError) { Net::HTTP.start('example.com', 443) { nil } }
  end
end

