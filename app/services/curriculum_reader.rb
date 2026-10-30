# frozen_string_literal: true

# 便覧PDFの1ページ(画像とテキスト)をAIに読ませ、下書きに入れる形で返す窓口。
#
# 窓口が持つのは、何を聞くか(Prompts)、どんな形で答えさせるか(Schemas)、失敗したらどうするか(再試行と形の検査)。
# HTTP は知らない。呼び出しは client が1回ぶん引き受ける(いまは CurriculumReader::Gemini)。
# 無料枠が変わっても、差し替えるのは client の1ファイルだけにするための分け方。
#
# 学生の履修・成績は、ここを通らない。外へ出るのは便覧のページ画像と、そのテキストだけ。
class CurriculumReader
  # 再試行しても読めなかった、または答えの形が違った。「半端な読み取り」は返さず、これにする。
  class Error < StandardError; end

  # client が呼び出しに失敗したとき(HTTP が200でない、通信が切れた)に投げる。status は HTTP の状態コード、通信の失敗では nil。
  # 窓口はこれを受けて、再試行するか Error にするかを決める。
  class RequestFailed < StandardError
    attr_reader :status

    # retry_after は、応答の Retry-After が言う待ち秒数(無ければ nil)。
    attr_reader :retry_after

    def initialize(message = nil, status: nil, retry_after: nil)
      super(message)
      @status = status
      @retry_after = retry_after
    end
  end

  PROVIDER = Gemini

  API_KEY_ENV = 'CURRICULUM_READER_API_KEY'
  # 同じ問いを最大3回まで(3回目の失敗のあとには待たない)。
  # 待ちは、応答に Retry-After があればその秒数(MAX_RETRY_AFTER を上限にする。誤った値や悪意のある値で、リクエストを止めないため)。
  # 無ければ、5xx と通信の失敗は BACKOFF_BASE 秒から、429 は RATE_LIMIT_BACKOFF_BASE 秒から、倍々に増やす。
  # 無料枠の上限は1分あたりで数えられることが多く、数秒の待ちでは窓が動かないので、429 は長く待つ。
  MAX_ATTEMPTS = 3
  BACKOFF_BASE = 4
  RATE_LIMIT_BACKOFF_BASE = 15
  MAX_RETRY_AFTER = 60

  # APIキーが設定されているか。無ければ、取り込み画面は読み取りボタンを出さず、手入力で使う。
  def self.available?
    ENV[API_KEY_ENV].present?
  end

  def initialize(client: PROVIDER.new, sleeper: ->(seconds) { sleep(seconds) })
    @client = client
    @sleeper = sleeper
  end

  # 要件表のページを読む。{ 'categories' =>, 'roles' =>, 'rules' =>, 'display' => }。
  # 1ページに書かれている分だけで、複数ページにまたがる要件をまとめるのは呼び出し側。
  def read_requirements(text:, image_path:)
    answer = ask(Prompts.requirements(text: text), image_path, Schemas.requirements)
    problems = Answer.requirements_problems(answer)
    raise Error, "読み取りの答えが要件表の形ではありません: #{problems.first(3).join('、')}" if problems.any?

    Answer.tidy_requirements(answer)
  end

  # 科目表のページを読む。{ 'courses' => }。
  # categories・roles は、要件表の読み取りで確定したもの(キーの文字列か、key・label を持つ Hash)。categories は空にできない(ArgumentError)。
  # 科目の区分は categories のどれか1つ、科目の役割(roles)は roles のうち0個以上に限る。一覧にないキーは作らせない。
  # roles を渡さなければ、どの科目の roles も空になる。
  def read_courses(text:, image_path:, categories:, roles: [])
    category_entries = keyed_entries(categories, 'categories')
    # 区分は要件表の読み取りで先に決める。空のまま科目表を読ませると、ページごとに別の区分名が返る。
    raise ArgumentError, 'categories が空です。先に要件表を読んで区分を決めてください。' if category_entries.empty?

    role_entries = keyed_entries(roles, 'roles')
    schema = Schemas.courses(category_entries.pluck(:key), role_entries.pluck(:key))
    prompt = Prompts.courses(text: text, categories: category_entries, roles: role_entries)
    answer = ask(prompt, image_path, schema)
    problems = Shape.problems(answer, schema)
    raise Error, "読み取りの答えが科目表の形ではありません: #{problems.first(3).join('、')}" if problems.any?

    Answer.tidy_courses(answer)
  end

  private

  # 呼び出して、答えが Hash であることまで確かめて返す。中身の形の検査は呼び出し元が持つスキーマで行う。
  def ask(prompt, image_path, schema)
    answer = call_with_retry(prompt, image_path, schema)
    raise Error, '読み取りの答えがJSONのオブジェクトではありません。' unless answer.is_a?(Hash)

    answer
  end

  # 429・5xx・通信の失敗だけをやり直す。400・401・403・404 は、同じ問いを送り直しても同じなので、すぐ諦める。
  # 答えの形が違うときも、ここでは再試行しない(呼び出しの失敗ではなく、読み取りの失敗)。
  def call_with_retry(prompt, image_path, schema)
    attempts = 0
    begin
      attempts += 1
      @client.generate(prompt: prompt, image_path: image_path, schema: schema)
    rescue RequestFailed => e
      if retryable?(e) && attempts < MAX_ATTEMPTS
        @sleeper.call(wait_seconds(e, attempts))
        retry
      end
      detail = e.status ? "HTTP #{e.status}" : e.message
      raise Error, "読み取りを呼び出せませんでした(#{detail}、#{attempts}回試しました)。"
    end
  end

  def retryable?(error)
    status = error.status
    status.nil? || status == 429 || status.between?(500, 599)
  end

  # 次の試しまでの待ち秒数。attempts は、いま失敗した試しの回数(1始まり)。
  def wait_seconds(error, attempts)
    return error.retry_after.clamp(1, MAX_RETRY_AFTER) if error.retry_after

    base = error.status == 429 ? RATE_LIMIT_BACKOFF_BASE : BACKOFF_BASE
    base * (2**(attempts - 1))
  end

  # 区分・役割を { key:, label: } にそろえる。キーだけの文字列も、便覧の categories の要素(String キーの Hash)も受ける。
  def keyed_entries(list, name)
    entries = Array(list).map { |item| keyed_entry(item) }
    raise ArgumentError, "#{name} に key のない要素があります" if entries.any? { |entry| entry[:key].empty? }

    entries.uniq { |entry| entry[:key] }
  end

  def keyed_entry(item)
    return { key: item.to_s, label: nil } unless item.is_a?(Hash)

    { key: (item['key'] || item[:key]).to_s, label: (item['label'] || item[:label]).presence }
  end
end

