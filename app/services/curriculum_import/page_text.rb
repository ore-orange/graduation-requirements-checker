# frozen_string_literal: true

module CurriculumImport
  # gs の txtwrite が書いたページの文字を、AIに渡せる形に整える。
  module PageText
    LATIN = /[A-Za-z]/

    # gs の出力は、表を文字の升目に並べるために余白の空白でできている(1ページで200KBを超えることもある)。
    # 余白は縮めるが、列の境は残す。空白の並びは1つのタブにし、隣り合う列を1つの語に見せない。
    # ただし英単語の間の空白1つ(Frontiers of Engineering)だけは本文の空白なので、そのまま残す。
    # 実際の便覧の出力では、空白が2つ以上の並び(1140か所)は英単語の間に1つも無く、すべて列の境だった。
    # 空白1つの並びは、英字どうしの間の10か所を除く400か所がほぼ列の境(科目番号|科目名、科目名|単位など)だった。
    # 日本語の文章は語の間に空白を入れないので、空白の幅ではなく「英字に挟まれた1つか」で本文の空白を見分ける。
    # DBに入れられない制御文字も除く。
    def self.tidy(raw)
      raw.dup.force_encoding(Encoding::UTF_8).scrub('').gsub(/[\u0000-\u0008\u000B-\u001F]/, '')
         .lines.filter_map { |line| separate_columns(line.strip).presence }.join("\n")
    end

    def self.separate_columns(line)
      line.gsub(/ +/) do |run|
        gap = Regexp.last_match
        word_space = run.size == 1 && gap.pre_match.match?(/#{LATIN}\z/o) && gap.post_match.match?(/\A#{LATIN}/o)
        word_space ? run : "\t"
      end
    end
    private_class_method :separate_columns
  end
end

