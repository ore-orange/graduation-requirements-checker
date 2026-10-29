# frozen_string_literal: true

module CurriculumImport
  # gs の txtwrite が書いたページの文字を、AIに渡せる形に整える。
  module PageText
    LATIN = /[A-Za-z]/

    # gs の出力は、表を文字の升目に並べるために余白の空白でできている(1ページで200KBを超えることもある)。
    # 余白は縮めるが、列の境は残す。空白の並びは1つのタブにし、隣り合う列を1つの語に見せない。
    # ただし英単語の間の空白1つ(Frontiers of Engineering)は、ほとんどが本文の空白なので、そのまま残す。
    # 実際の便覧の出力では、空白が2つ以上の並び(1140か所)は英単語の間に1つも無く、すべて列の境だった。
    # 空白1つの並びは、英字どうしの間の10か所を除く400か所がほぼ列の境(科目番号|科目名、科目名|単位など)だった。
    # 英字に挟まれた10か所のうち8か所は英単語の間だが、2か所(国際インターンシップI GE、同II GE)は科目名がローマ数字の
    # Iで終わるだけの列の境で、これは本文の空白として残してしまう。空白の無い隣の列(選2国際インターン…)と同じく、画像で補う。
    #
    # タブは「別のセル」を表すだけで、「同じ表の隣のセル」を表さない。
    # 1ページに表が横に並ぶページ(便覧の2ページ目、14ページ目)では、左の表と右の表の境も同じタブになる。
    # 空白の幅では表の境を見分けられない(表の中の空のセルの幅が、表の境より広い)ので、そこは区別していない。
    # 読む側は、画像を正とし、このテキストは補助として扱うこと。
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

