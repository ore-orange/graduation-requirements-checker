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

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end
  end

  PROVIDER = Gemini

  API_KEY_ENV = 'CURRICULUM_READER_API_KEY'
  # 同じ問いを最大3回まで。待ちは BACKOFF_BASE 秒、その倍…と増やす(3回目の失敗のあとには待たない)。
  # 無料枠の1分あたりの上限に当たったときも、2回待てば窓が動く見込みで、リクエストを何十秒も止めない長さにする。
  MAX_ATTEMPTS = 3
  BACKOFF_BASE = 4

  # APIキーが設定されているか。無ければ、取り込み画面は読み取りボタンを出さず、手入力で使う。
  def self.available?
    ENV[API_KEY_ENV].present?
  end

  def initialize(client: PROVIDER.new, sleeper: ->(seconds) { sleep(seconds) })
    @client = client
    @sleeper = sleeper
  end

  # 要件表のページを読む。{ 'categories' =>, 'rules' =>, 'display' => }。
  # 1ページに書かれている分だけで、複数ページにまたがる要件をまとめるのは呼び出し側。
  def read_requirements(text:, image_path:)
    answer = ask(Prompts.requirements(text: text), image_path, Schemas.requirements)
    problems = Answer.requirements_problems(answer)
    raise Error, "読み取りの答えが要件表の形ではありません: #{problems.first(3).join('、')}" if problems.any?

    Answer.tidy_requirements(answer)
  end

  # 科目表のページを読む。{ 'courses' => }。categories は要件表の読み取りで確定した区分(キーの文字列か、key・label を持つ Hash)。
  # 科目の区分は、この一覧のどれかに限る。
  def read_courses(text:, image_path:, categories:)
    entries = category_entries(categories)
    schema = Schemas.courses(entries.pluck(:key))
    answer = ask(Prompts.courses(text: text, categories: entries), image_path, schema)
    problems = Shape.problems(answer, schema)
    raise Error, "読み取りの答えが科目表の形ではありません: #{problems.first(3).join('、')}" if problems.any?

    answer
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
        @sleeper.call(BACKOFF_BASE * (2**(attempts - 1)))
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

  # 区分を { key:, label: } にそろえる。キーだけの文字列も、便覧の categories の要素(String キーの Hash)も受ける。
  def category_entries(categories)
    entries = Array(categories).map { |category| category_entry(category) }
    raise ArgumentError, 'categories に key のない区分があります' if entries.any? { |entry| entry[:key].empty? }

    entries.uniq { |entry| entry[:key] }
  end

  def category_entry(category)
    return { key: category.to_s, label: nil } unless category.is_a?(Hash)

    { key: (category['key'] || category[:key]).to_s, label: (category['label'] || category[:label]).presence }
  end
end

