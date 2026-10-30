# frozen_string_literal: true

module CurriculumImport
  # 科目番号の接頭辞(と百の位)から、科目の区分を推定する。AIの読み取りに対する、独立した第二の意見。
  #
  # 区分の取り違えは、判定が「卒業できます」に傾く間違いの中でも気づきにくい(科目数も単位合計も合ったまま、
  # 単位だけが別の区分に流れる)。番号の付け方は大学全体の決まりなので、AIとは別の根拠で見張れる。
  #
  # 対応表はコードに持たない。渡された科目表から毎回作る。区分の名前は便覧ごとに違うので、固定の表を持つと
  # 特定の年度専用になる。推定は読み取りを上書きしない。食い違いを mismatches に出して、人が見る。
  class CategoryInference
    # 食い違いと言うために、その科目を除いた他の科目が最低これだけ揃って同じ区分を指していること。
    # 少ない根拠では、どちらが誤りか分からず、正しい科目を疑うノイズになる。2024年度の知能情報の便覧(正しいと
    # 確かめてある)で測ると、2では離散数学(知能103)が、3からは外れる。3以上でも、必修が選択の番号帯に
    # 入る科目(総合実験・プログラミングⅡ)は残る。番号の付け方に例外があるので、食い違いは誤りの断定ではなく、
    # 人が見る印にとどめる。
    MIN_SUPPORT = 3

    Entry = Struct.new(:number, :category, :prefix, :hundreds)
    private_constant :Entry

    def initialize(courses)
      @entries = Array(courses).filter_map { |course| entry_for(course) }
      @by_hundreds = tally(:hundreds)
      @by_prefix = tally(:prefix)
    end

    # 番号から推定した区分。決められなければ nil。
    # 百の位まで含む鍵で1区分にしか現れなければそれを採り、なければ(その百の位が未見のときだけ)接頭辞だけの鍵で見る。
    # 英語(外1xx)とそれ以外の外国語(外2xx〜)のように、接頭辞が複数の区分にまたがっても百の位で決まることがある。
    def inferred(number)
      prefix = CourseNumber.prefix(number)
      return unless prefix

      decide(@by_hundreds[CourseNumber.hundreds(number)], @by_prefix[prefix], 1)
    end

    # 推定と読み取りが食い違う科目。科目自身を根拠から外して推定する(自分の読み取りで自分を正当化しない)。
    # 「知能993だけが工学融合ではない区分に読まれた」ような、他の科目が揃って指す先から外れた科目が出る。
    def mismatches
      @mismatches ||= @entries.filter_map do |entry|
        inferred = decide(without(@by_hundreds[entry.hundreds], entry), without(@by_prefix[entry.prefix], entry),
                          MIN_SUPPORT)
        next if inferred.nil? || inferred == entry.category

        { number: entry.number, read: entry.category, inferred: inferred }
      end
    end

    private

    # 番号か区分が読めない科目は、根拠にも食い違いにも入れない(読めないことは、その接頭辞に属する根拠にならない)。
    def entry_for(course)
      return unless course.is_a?(Hash)

      prefix = CourseNumber.prefix(course['number'])
      category = course['category']
      return if prefix.nil? || !category.is_a?(String) || category.empty?

      Entry.new(course['number'], category, prefix, CourseNumber.hundreds(course['number']))
    end

    # 鍵ごとに「区分 => 科目数」を数える。
    def tally(field)
      @entries.each_with_object({}) do |entry, tallies|
        counts = (tallies[entry.public_send(field)] ||= Hash.new(0))
        counts[entry.category] += 1
      end
    end

    def without(counts, entry)
      remaining = (counts || {}).dup
      remaining[entry.category] -= 1
      remaining.delete(entry.category) if remaining[entry.category] <= 0
      remaining
    end

    # 百の位の鍵が1区分に決まればそれ、鍵が未見のときだけ接頭辞の鍵。百の位の鍵が複数の区分にまたがるなら、
    # 接頭辞の鍵はそれを含むので必ず決まらない。
    def decide(by_hundreds, by_prefix, min_support)
      [by_hundreds, by_prefix].each do |counts|
        next if counts.blank?

        return sole_category(counts, min_support)
      end
      nil
    end

    def sole_category(counts, min_support)
      counts.keys.first if counts.size == 1 && counts.values.sum >= min_support
    end
  end
end

