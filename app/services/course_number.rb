# frozen_string_literal: true

# 科目番号(例: 知能103, 外203, C101)を、接頭辞と百の位に分ける。
#
# 接頭辞は開講する課程を示し、外国語は接頭辞と百の位の組で言語を見分ける
# (外1xx は英語、外2xx はドイツ語 …)。読めない値は nil を返す。
module CourseNumber
  # 数字以外の並び(接頭辞)の後に、末尾の数字列の先頭1桁を取る。数字列の残りは捨てる。
  PATTERN = /\A(\D+)(\d)\d*\z/

  def self.prefix(number)
    split(number)&.first
  end

  def self.hundreds(number)
    split(number)&.join
  end

  # 空白(半角・全角・タブ)を取り除き、全角数字を半角にそろえてから分ける。
  # 数字の位置に関係なく空白を消すので、PDFから読んだ値の余白で別の接頭辞にならない。
  # 戻り値は [接頭辞, 百の位] か nil。
  def self.split(number)
    normalized = number.to_s.delete(" 　\t").tr('０-９', '0-9')
    normalized.match(PATTERN)&.captures
  end
  private_class_method :split
end

