# frozen_string_literal: true

class CurriculumReader
  # AIへの依頼文。要件表用と科目表用の2本。どちらにも、ページの画像とテキストが付く。
  #
  # 画像とテキストの扱いは、取り出し側(CurriculumImport::PageSource)で分かった事実に基づく。
  #  - Ghostscript は壊れた内容ストリームのテキストを、エラーなしで途中まで切ることがある。
  #    テキストに無い行が、ページにはあることがある。
  #  - 2〜3つの表が左右に並ぶページ(2024年度の便覧では2・14ページ目)では、テキストが並んだ表を1つの格子として
  #    行ごとに出すので、1行に別々の表のセルが混ざる。幅で表の境を決められる閾値は、測っても見つからなかった。
  #    表の切れ目は、画像でしか分からない。
  #    依頼文にはページ番号を書かない。1ページずつ送るので、「これは何ページ目か」をモデルに考えさせることになり、
  #    便覧によってページも違う。「表が左右に並んでいるとき」という条件で書く。
  module Prompts
    class << self
      # 要件表(卒業に必要な単位の表)のページ用。区分・規則・表示の3つを返させる。
      def requirements(text:)
        <<~PROMPT
          あなたは、大学の履修便覧(PDF)の1ページを読み取り、卒業要件をJSONに写す。
          このページは「要件表」(卒業に必要な単位や、必修・選択の条件が書かれた表)のページとして選ばれている。

          #{Guides::READING_RULES}
          #{Guides::REQUIREMENTS_SPEC}
          ## このページのテキスト

          #{page_text(text)}
        PROMPT
      end

      # 科目表のページ用。categories と roles は、要件表の読み取りで確定した区分・役割(key と、あれば label)。
      def courses(text:, categories:, roles: [])
        <<~PROMPT
          あなたは、大学の履修便覧(PDF)の1ページを読み取り、科目表をJSONに写す。
          このページは「科目表」(科目番号・科目名・単位数などが1行ずつ並んだ表)のページとして選ばれている。

          #{Guides::READING_RULES}
          ## このページから読むもの

          画像に載っている科目の行を、すべて courses に入れる。1行も読み落とさない。
          同じ科目が別の表に重ねて載っていても、行ごとにそのまま返す(重複の判断は、あとで機械と人がする)。
          ページ番号(source_page)は返さない。呼び出し側が付ける。

          各科目に次の欄を付ける。
          - number: 科目番号(例: 知能101)。印字されたとおりに写す。番号が無い・読めない行は null。
          - name: 科目名。
          - credits: 単位数。数。書かれていない・読めない行は null。
          - category: 科目が属する区分。下の区分の一覧にある key のどれか1つ。
          - required: 必修なら true、そうでなければ false。画像の表の凡例や見出し(必修・選択の印など)で決める。
          - language: 外国語の科目なら、その言語を英小文字の英語で(english, german, french, spanish, chinese, korean,
            indonesian, thai, latin, russian など)。外国語でなければ null。
          - requires_approval: 表の行・見出し・このページの注記が、この科目の履修登録に指導教員の承認が必要だとしているときだけ true。
            そうでなければ false。注記が別のページにありそうで、この科目に当たるか分からないときは false にして review_reason に書く。
            (承認を得たかどうかは、学生ごとの話なので読まない。)
          #{roles_bullet(roles)}- review_reason: 読み取りに自信がない・区分が決めにくい・表の中で食い違っているときに、その理由を一言。問題がなければ null。

          ## 区分の一覧

          すべての科目を、次の区分のどれか1つに入れる。一覧にない区分の名前を作らない。
          区分が決めにくい科目は、いちばん近い区分に入れて、review_reason に理由を書く。
          区分は、表の見出しや凡例、科目の並びを画像で見て決める。科目番号の接頭辞だけで決めない。

          #{category_lines(categories)}
          #{role_section(roles)}
          ## このページのテキスト

          #{page_text(text)}
        PROMPT
      end

      private

      def page_text(text)
        text = text.to_s.strip
        return '(このページのテキストは取り出せませんでした。画像だけで読むこと。)' if text.empty?

        "(以下はページから機械で取り出したテキスト。列の区切りはタブ。表の境とは限らない。)\n#{text}"
      end

      # 役割の一覧が無いときは、roles の欄そのものを聞かない(スキーマにも無い)。
      def roles_bullet(roles)
        return '' if roles.empty?

        "- roles: 下の役割の一覧のうち、この科目が担うものの key の配列。担う役割がなければ空の配列(ほとんどの科目はそうなる)。\n"
      end

      # 役割の一覧は、渡されたときだけ書く。無いのに空の見出しを置くと、役割を探させてしまう。
      def role_section(roles)
        return '' if roles.empty?

        "\n#{Guides::ROLES_GUIDE}\n#{entry_lines(roles)}\n"
      end

      def category_lines(categories)
        entry_lines(categories)
      end

      def entry_lines(entries)
        entries.map { |entry| entry[:label] ? "- #{entry[:key]}: #{entry[:label]}" : "- #{entry[:key]}" }.join("\n")
      end
    end
  end
end

