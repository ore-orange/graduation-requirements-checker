# frozen_string_literal: true

# 便覧PDFの要件表の1ページ(画像とテキスト)を Gemini に読ませ、区分・役割・規則・画面の章立てを返す。
#
# 何を聞くか(Prompt)、どんな形で答えさせるか(Schema)、答えが使えるか(Answer)をここで持つ。
# 通信とやり直しは GeminiClient に任せる。学生の履修・成績は、ここを通らない。外へ出るのは便覧のページだけ。
class RequirementsReader
  # 読めなかった、または答えの形が使えなかった。メッセージはそのままページの行に出す。
  class Error < StandardError; end

  def initialize(client: GeminiClient.new)
    @client = client
  end

  # { 'categories' =>, 'roles' =>, 'rules' =>, 'display' => }。1ページに書かれている分だけ。
  def read(image_path:, text:)
    answer = @client.generate_json(prompt: Prompt.call(text), schema: Schema.call, image_path: image_path)
    problems = Answer.problems(answer)
    raise Error, "読み取りの答えが要件表の形ではありません: #{problems.first(3).join('、')}" if problems.any?

    Answer.tidy(answer)
  rescue GeminiClient::Error => e
    raise Error, e.message
  end
end

