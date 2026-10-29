# frozen_string_literal: true

module CurriculumImport
  # gs の txtwrite が書いたページの文字を、AIに渡せる形に整える。
  module PageText
    # gs の出力は、表の位置を保つために余白の空白でできている(1ページで200KBを超えることもある)。
    # 行頭と行末の空白・空行を落とし、列の区切りが分かる程度(半角2つ)に詰める。DBに入れられない制御文字も除く。
    def self.tidy(raw)
      raw.dup.force_encoding(Encoding::UTF_8).scrub('').gsub(/[\u0000-\u0008\u000B-\u001F]/, '')
         .lines.filter_map { |line| line.strip.gsub(/\s{2,}/, '  ').presence }.join("\n")
    end
  end
end

