# frozen_string_literal: true

# 科目番号(例: 知能103, 外203, C101)を、接頭辞と百の位に分ける。
#
# 接頭辞は開講する課程を示す。外国語の百の位は、英語(外1xx)とそれ以外の外国語を分けるが、言語を決めるものではない。
# 外7xx にはインドネシア語・タイ語・ラテン語・ロシア語が入っているので、言語は科目の language 欄で見る。
# 読めない値は nil を返す。
module CourseNumber
  # 数字以外の並び(接頭辞)の後に、末尾の数字列の先頭1桁を取る。数字列の残りは捨てる。
  PATTERN = /\A(\D+)(\d)\d*\z/
  private_constant :PATTERN

  def self.prefix(number)
    split(number)&.first
  end

  def self.hundreds(number)
    split(number)&.join
  end

  # 空白(改行・ノーブレークスペース・全角スペースを含む)を取り除き、全角の数字と英字を
  # 半角にそろえる。PDFから読んだ値の余白や全角の綴りで別の番号にならないように。
  # 取り込みの突き合わせが「表記違いの同じ番号」を見つけるときにも、同じ整え方を使う。
  def self.normalize(number)
    number.to_s.gsub(/[[:space:]]/, '').tr('０-９Ａ-Ｚａ-ｚ', '0-9A-Za-z')
  end

  # 整えてから分ける。戻り値は [接頭辞, 百の位] か nil。
  def self.split(number)
    normalize(number).match(PATTERN)&.captures
  end
  private_class_method :split
end

