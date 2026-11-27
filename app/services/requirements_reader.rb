# frozen_string_literal: true

# 便覧PDFの要件表の1ページ(画像とテキスト)を Gemini に読ませ、区分・役割・規則・画面の章立てを返す。
#
# 何を聞くか(Prompt)、どんな形で答えさせるか(Schema)、答えが使えるか(Answer)をここで持つ。
# 通信とやり直しは GeminiClient に任せる。学生の履修・成績は、ここを通らない。外へ出るのは便覧のページだけ。
class RequirementsReader
  # 読めなかった、または答えの形が使えなかった。メッセージはそのままページの行に出すので、事務の方が読む言葉で書く。
  class Error < StandardError; end

  # 読めなかった理由(GeminiClient::Error#reason)ごとの、画面に出す文言。
  MESSAGES = {
    busy: 'AIが混み合っていて読み取れませんでした。少し時間をおいてから「読み直す」を押してください。',
    no_response: 'AIから応答がありませんでした。少し時間をおいてから「読み直す」を押してください。',
    setup: '読み取りの設定に問題があり、読み取れませんでした。システムの管理担当者に連絡してください。',
    input: 'このページの画像をAIに送れませんでした。PDFを取り込み直してください。',
    answer: 'AIの読み取り結果を受け取れませんでした。もう一度「読み直す」を押してください。'
  }.freeze

  # 要件表は区分・規則・章立てをまとめて答えさせるので、答えが長く、1分を超えることがある。
  # 読み取りはバックグラウンドのジョブで行うので、画面を待たせずに長く待てる。
  READ_TIMEOUT = 180

  def initialize(client: GeminiClient.new(read_timeout: READ_TIMEOUT))
    @client = client
  end

  # { 'categories' =>, 'roles' =>, 'rules' =>, 'display' =>, 'warnings' => }。1ページに書かれている分だけ。
  # warnings は、形が違って取り込まなかった規則などの知らせ。
  def read(image_path:, text:)
    raw = @client.generate_json(prompt: Prompt.call(text), schema: Schema.call, image_path: image_path)
    answer, warnings = Answer.call(raw)
    answer.merge('warnings' => warnings)
  rescue GeminiClient::Error => e
    # 詳しい理由(状態コードなど)は開発者向けにログへ残し、画面には分かる言葉だけを出す。
    Rails.logger.warn("要件表の読み取りに失敗しました: #{e.message}")
    raise Error, MESSAGES.fetch(e.reason, MESSAGES[:answer])
  end
end

