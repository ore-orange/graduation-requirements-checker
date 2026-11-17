# frozen_string_literal: true

module CurriculumImport
  # 区分の number_patterns から、科目番号で区分を引く。規則は GraduationAssessment::Catalogue#pattern_category_for と同じ
  # (百の位の鍵 → 接頭辞の鍵の順)。
  #
  # Catalogue を使わずに切り出したのは、Catalogue が壊れた文書(重複した番号・区分など)で ArgumentError を投げるため。
  # 取り込み途中の下書きは壊れていることがあり、絞り込みや科目名簿がそこで止まってはいけない。
  # だからここは何も検めず、読めない区分は黙って飛ばす(引けなければ nil で、呼び出し側は「決まらない」として残す)。
  # Catalogue 側は、判定の経路に触れないよう変えていない。2つの規則がずれたら、このクラスのテストで気づく。
  class NumberPatterns
    def initialize(categories)
      @by_hundreds = {}
      @by_prefix = {}
      Array(categories).grep(Hash).each { |category| index(category) }
    end

    # 当たる区分のキー。どれにも当たらなければ nil。
    def category_for(number)
      hundreds = CourseNumber.hundreds(number)
      prefix = CourseNumber.prefix(number)
      return nil unless hundreds || prefix

      @by_hundreds[hundreds] || @by_prefix[prefix]
    end

    private

    # 末尾が数字なら百の位の鍵(例: "外1")、そうでなければ接頭辞の鍵(例: "外")。重複は先勝ち(Catalogue と同じ)。
    def index(category)
      Array(category['number_patterns']).grep(String).each do |pattern|
        target = pattern.match?(/\d\z/) ? @by_hundreds : @by_prefix
        target[pattern] ||= category['key']
      end
    end
  end
end

