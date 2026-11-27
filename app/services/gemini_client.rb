# frozen_string_literal: true

require 'net/http'
require 'json'
require 'base64'
require 'time'

# Google AI Studio(Gemini API)に、依頼文と画像を渡して、指定した形のJSONを答えさせる。
#
# 何を読ませるか(便覧の要件表・科目表など)は知らない。受け取るのは依頼文・答えの形(スキーマ)・画像で、
# 返すのは答えのJSON(Hash)。使えなかったときは、理由を添えた Error を投げる。半端な答えは返さない。
#
# APIキーはリクエストのヘッダにだけ入れる。URL・例外のメッセージ・ログには出さない。
class GeminiClient
  class Error < StandardError; end

  # 1回の呼び出しの失敗。やり直すかどうかを決めるために、状態コードと Retry-After を持つ。外には出さない。
  class RequestFailed < StandardError
    attr_reader :status, :retry_after

    def initialize(message, status: nil, retry_after: nil)
      super(message)
      @status = status
      @retry_after = retry_after
    end
  end

  ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models'
  API_KEY_ENV = 'GEMINI_API_KEY'
  MODEL_ENV = 'GEMINI_MODEL'
  # gemini-2.5-flash は新規のキーでは使えない(2026-11-02 時点)。3.5-flash が応答することを確認している。
  DEFAULT_MODEL = 'gemini-3.5-flash'
  MODEL_FORMAT = /\A[A-Za-z0-9._-]+\z/

  OPEN_TIMEOUT = 10
  WRITE_TIMEOUT = 30
  # 画像つきで表を読ませると、答えが出るまで数十秒かかる。混雑したモデルは応答しないまま止まることがあり、
  # 長く待つと3回の試しで数分止まるので、60秒で区切る。
  READ_TIMEOUT = 60
  # リクエスト全体の上限(20MB)に収まる画像だけを送る。
  MAX_IMAGE_BYTES = 15 * 1024 * 1024
  MIME_TYPES = { '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg' }.freeze
  NETWORK_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError].freeze

  # 同じ問いを最大3回まで。待ちは Retry-After があればその秒数(上限あり)、無ければ倍々に増やす。
  # 無料枠の上限は1分単位で数えられることが多いので、429 は長めに待つ。
  MAX_ATTEMPTS = 3
  BACKOFF_BASE = 4
  RATE_LIMIT_BACKOFF_BASE = 15
  MAX_RETRY_AFTER = 60

  # APIキーが設定されているか。無ければ、呼び出す機能を画面に出さない。
  def self.available?
    ENV[API_KEY_ENV].present?
  end

  # transport は (uri, headers, body) を受けて [状態コード, 本文, 応答ヘッダ(小文字キーの Hash)] を返すもの。テストが偽物を渡す。
  def initialize(api_key: ENV.fetch(API_KEY_ENV, nil), model: ENV.fetch(MODEL_ENV, DEFAULT_MODEL),
                 transport: method(:post), sleeper: ->(seconds) { sleep(seconds) })
    model = model.presence || DEFAULT_MODEL
    raise ArgumentError, 'モデル名に使えない文字があります' unless model.match?(MODEL_FORMAT)

    @api_key = api_key
    @model = model
    @transport = transport
    @sleeper = sleeper
  end

  # schema は小文字の型名で書いた JSON Schema(type: 'object' など)。答えはその形の Hash。
  # image_path を渡すと、画像も一緒に読ませる(PNG・JPEG)。
  def generate_json(prompt:, schema:, image_path: nil)
    raise Error, 'APIキーが設定されていません。' if @api_key.blank?

    body = JSON.generate(request_body(prompt, schema, image_path))
    parse(call_with_retry(body))
  end

  private

  # 429・5xx・通信の失敗だけをやり直す。400・401・403・404 は、送り直しても同じなのですぐ諦める。
  def call_with_retry(body)
    attempts = 0
    begin
      attempts += 1
      call(body)
    rescue RequestFailed => e
      if retryable?(e) && attempts < MAX_ATTEMPTS
        @sleeper.call(wait_seconds(e, attempts))
        retry
      end
      raise Error, "Geminiを呼び出せませんでした(#{e.message}、#{attempts}回試しました)。"
    end
  end

  def call(body)
    status, response, response_headers = @transport.call(uri, headers, body)
    raise failure(status, response, response_headers) unless status == 200

    response
  rescue *NETWORK_ERRORS => e
    # 例外のメッセージには接続先などが入り得るので、種類だけを載せる。
    raise RequestFailed, "通信に失敗しました: #{e.class}"
  end

  def retryable?(error)
    error.status.nil? || error.status == 429 || error.status.between?(500, 599)
  end

  # attempts は、いま失敗した試しの回数(1始まり)。
  def wait_seconds(error, attempts)
    return error.retry_after.clamp(1, MAX_RETRY_AFTER) if error.retry_after

    base = error.status == 429 ? RATE_LIMIT_BACKOFF_BASE : BACKOFF_BASE
    base * (2**(attempts - 1))
  end

  def uri
    URI("#{ENDPOINT}/#{@model}:generateContent")
  end

  def headers
    { 'content-type' => 'application/json', 'x-goog-api-key' => @api_key }
  end

  def request_body(prompt, schema, image_path)
    parts = [{ text: prompt }]
    parts << { inlineData: image_part(image_path) } if image_path
    { contents: [{ parts: parts }],
      generationConfig: { responseMimeType: 'application/json', responseSchema: dialect(schema), temperature: 0 } }
  end

  def image_part(image_path)
    mime = MIME_TYPES[File.extname(image_path.to_s).downcase]
    raise Error, '送れる画像の形式はPNGかJPEGだけです。' unless mime

    data = File.binread(image_path)
    raise Error, '画像が大きすぎて送れません。' if data.bytesize > MAX_IMAGE_BYTES

    { mimeType: mime, data: Base64.strict_encode64(data) }
  rescue SystemCallError
    raise Error, '画像を読めませんでした。'
  end

  # Gemini のスキーマは型名を大文字で書く(STRING・OBJECT など)。値が文字列の type だけを直す
  # (type という名前の欄を持つ properties には触れない)。
  def dialect(schema)
    case schema
    when Hash
      schema.to_h { |key, value| [key, key.to_s == 'type' && value.is_a?(String) ? value.upcase : dialect(value)] }
    when Array then schema.map { |value| dialect(value) }
    else schema
    end
  end

  # 失敗の理由。Google の状態名(PERMISSION_DENIED など)は載せるが、本文の文章は載せない。
  def failure(status, response, response_headers)
    error = json_or_nil(response)&.then { |body| body['error'] if body.is_a?(Hash) }
    reason = label(error['status'], fallback: nil) if error.is_a?(Hash)
    RequestFailed.new(['HTTP', status, reason].compact.join(' '),
                      status: status, retry_after: retry_after_seconds(response_headers&.[]('retry-after')))
  end

  # Retry-After は秒数か、HTTP の日時。読めなければ nil。
  def retry_after_seconds(value)
    value = value.to_s.strip
    return if value.empty?
    return value.to_i if value.match?(/\A\d{1,9}\z/)

    [(Time.httpdate(value) - Time.current).ceil, 0].max
  rescue ArgumentError
    nil
  end

  def parse(response)
    envelope = parse_json(response, 'Geminiの応答がJSONではありません。')
    candidate = envelope.dig('candidates', 0) if envelope.is_a?(Hash)
    raise Error, "Geminiが答えを返しませんでした(#{label(block_reason(envelope))})。" unless candidate.is_a?(Hash)

    finish = candidate['finishReason']
    raise Error, "Geminiの答えが最後まで出ませんでした(#{label(finish)})。" unless finish == 'STOP'

    answer = parse_json(answer_text(candidate), 'Geminiの答えがJSONではありません。')
    raise Error, 'Geminiの答えがJSONのオブジェクトではありません。' unless answer.is_a?(Hash)

    answer
  end

  # 答えの文章。考えの断片(thought)は混ぜない。
  def answer_text(candidate)
    parts = candidate.dig('content', 'parts')
    Array(parts).filter_map { |part| part['text'] if part.is_a?(Hash) && !part['thought'] }.join
  end

  def block_reason(envelope)
    envelope.dig('promptFeedback', 'blockReason') if envelope.is_a?(Hash)
  end

  def parse_json(text, message)
    JSON.parse(text.to_s.dup.force_encoding(Encoding::UTF_8).scrub)
  rescue JSON::ParserError
    # パーサーのメッセージには本文が入り得るので、決まった文だけにする。
    raise Error, message
  end

  def json_or_nil(text)
    JSON.parse(text.to_s)
  rescue JSON::ParserError
    nil
  end

  # 状態名は、決まった形のときだけ文面に載せる。
  def label(value, fallback: '不明')
    value.is_a?(String) && value.match?(/\A[A-Z_]{1,40}\z/) ? value : fallback
  end

  # 既定の通信。標準の net/http で1回POSTする。
  def post(uri, headers, body)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT,
                                        write_timeout: WRITE_TIMEOUT) do |http|
      request = Net::HTTP::Post.new(uri, headers)
      request.body = body
      response = http.request(request)
      [response.code.to_i, response.body.to_s, { 'retry-after' => response['retry-after'] }]
    end
  end
end

