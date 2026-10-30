# frozen_string_literal: true

require 'net/http'
require 'json'
require 'base64'
require 'time'

class CurriculumReader
  # Google AI Studio(Gemini API)の generateContent を1回呼ぶ。プロバイダが替わるときに直すのは、このファイルだけ。
  #
  # 便覧のことは知らない。受け取るのは、依頼文・画像・答えのスキーマで、返すのは答えのJSON(Hash)。
  # 呼び出しが失敗したら RequestFailed(状態コード付き。再試行するかは窓口が決める)、
  # 呼び出しは通ったが答えが使えなければ Error を投げる。
  #
  # APIキーはリクエストのヘッダにだけ入れる。URL・ボディ・例外のメッセージ・ログには出さない
  # (URLに入れると、例外や接続のログに載ってしまう)。
  class Gemini
    ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models'
    DEFAULT_MODEL = 'gemini-2.5-flash'
    MODEL_ENV = 'CURRICULUM_READER_MODEL'
    MODEL_FORMAT = /\A[A-Za-z0-9._-]+\z/
    OPEN_TIMEOUT = 10
    WRITE_TIMEOUT = 30
    # 画像つきで表を読ませるので、答えが出るまで数十秒かかる。
    READ_TIMEOUT = 120
    # インラインで送れる上限(リクエスト全体で20MB)に収まる画像だけ送る。
    MAX_IMAGE_BYTES = 15 * 1024 * 1024
    MIME_TYPES = { '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg' }.freeze
    NETWORK_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError].freeze

    # transport は (uri, headers, body) を受けて [状態コード, 本文] か [状態コード, 本文, 応答のヘッダ(小文字のキーの Hash)] を返す
    # 呼び出し可能なもの。テストが偽物を渡す。
    def initialize(api_key: ENV.fetch(CurriculumReader::API_KEY_ENV, nil), model: ENV.fetch(MODEL_ENV, DEFAULT_MODEL),
                   transport: nil)
      raise ArgumentError, 'モデル名に使えない文字があります' unless model.to_s.match?(MODEL_FORMAT)

      @api_key = api_key
      @model = model
      @transport = transport || method(:post)
    end

    # 答えのJSONをHashにして返す。image_path が nil ならテキストだけを送る。
    def generate(prompt:, image_path:, schema:)
      raise CurriculumReader::Error, 'APIキーが設定されていません。' if @api_key.to_s.empty?

      body = JSON.generate(request_body(prompt, image_path, schema))
      status, response, response_headers = @transport.call(uri, headers, body)
      raise failure(status, response, response_headers) unless status == 200

      parse(response)
    end

    private

    def uri
      URI("#{ENDPOINT}/#{@model}:generateContent")
    end

    def headers
      { 'content-type' => 'application/json', 'x-goog-api-key' => @api_key }
    end

    def request_body(prompt, image_path, schema)
      parts = [{ text: prompt }]
      parts << { inlineData: image_part(image_path) } if image_path
      { contents: [{ parts: parts }],
        generationConfig: { responseMimeType: 'application/json', responseSchema: dialect(schema), temperature: 0 } }
    end

    def image_part(image_path)
      mime = MIME_TYPES[File.extname(image_path.to_s).downcase]
      raise CurriculumReader::Error, '送れる画像の形式はPNGかJPEGだけです。' unless mime

      data = File.binread(image_path)
      raise CurriculumReader::Error, 'ページ画像が大きすぎて送れません。' if data.bytesize > MAX_IMAGE_BYTES

      { mimeType: mime, data: Base64.strict_encode64(data) }
    rescue SystemCallError
      raise CurriculumReader::Error, 'ページ画像を読めませんでした。'
    end

    # Gemini のスキーマは型の名前を大文字で書く(STRING・OBJECT など)。窓口のスキーマは小文字の JSON Schema なので、ここで直す。
    # 値が文字列の type だけを直す。type という名前の欄(値は Hash)には触れない。
    def dialect(schema)
      case schema
      when Hash
        schema.to_h do |key, value|
          [key, key.to_s == 'type' && value.is_a?(String) ? value.upcase : dialect(value)]
        end
      when Array then schema.map { |value| dialect(value) }
      else schema
      end
    end

    # 失敗の理由。Google の状態名(PERMISSION_DENIED など、大文字と下線だけのもの)は載せるが、本文の文章は載せない。
    def failure(status, response, response_headers)
      reason = google_status(response)
      retry_after = retry_after_seconds(response_headers&.[]('retry-after'))
      CurriculumReader::RequestFailed.new(["HTTP #{status}", reason].compact.join(' '),
                                          status: status, retry_after: retry_after)
    end

    # Retry-After は秒数か、HTTP の日時。読めなければ nil(窓口が決めた待ちを使う)。上限は窓口が掛ける。
    def retry_after_seconds(value)
      value = value.to_s.strip
      return if value.empty?
      return value.to_i if value.match?(/\A\d{1,9}\z/)

      [(Time.httpdate(value) - Time.current).ceil, 0].max
    rescue ArgumentError
      nil
    end

    def google_status(response)
      value = JSON.parse(response.to_s).dig('error', 'status')
      value if value.is_a?(String) && value.match?(/\A[A-Z_]{1,40}\z/)
    rescue JSON::ParserError, TypeError, NoMethodError
      nil
    end

    def parse(response)
      envelope = parse_json(response, 'Geminiの応答がJSONではありません。')
      candidate = envelope.is_a?(Hash) ? envelope.dig('candidates', 0) : nil
      raise CurriculumReader::Error, "Geminiが答えを返しませんでした#{block_reason(envelope)}。" unless candidate.is_a?(Hash)

      finish = candidate['finishReason']
      raise CurriculumReader::Error, "Geminiの答えが最後まで出ませんでした(#{label(finish)})。" unless finish == 'STOP'

      answer = parse_json(answer_text(candidate), 'Geminiの答えがJSONではありません。')
      raise CurriculumReader::Error, 'Geminiの答えがJSONのオブジェクトではありません。' unless answer.is_a?(Hash)

      answer
    end

    # 答えの文章。考えの断片(thought)は混ぜない。
    def answer_text(candidate)
      parts = candidate.dig('content', 'parts')
      Array(parts).filter_map { |part| part['text'] if part.is_a?(Hash) && !part['thought'] }.join
    end

    def parse_json(text, message)
      JSON.parse(text.to_s.dup.force_encoding(Encoding::UTF_8).scrub)
    rescue JSON::ParserError
      # パーサーのメッセージには本文が入り得るので、固定の文だけにする。
      raise CurriculumReader::Error, message
    end

    def block_reason(envelope)
      reason = envelope.dig('promptFeedback', 'blockReason') if envelope.is_a?(Hash)
      reason ? "(#{label(reason)})" : ''
    end

    # 状態名は、決まった形のときだけ文面に載せる。
    def label(value)
      value.is_a?(String) && value.match?(/\A[A-Z_]{1,40}\z/) ? value : '不明'
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
    rescue *NETWORK_ERRORS => e
      # 例外のメッセージには接続先などが入り得るので、種類だけを載せる。
      raise CurriculumReader::RequestFailed, "通信に失敗しました(#{e.class})"
    end
  end
end

