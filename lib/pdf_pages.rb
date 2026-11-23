# frozen_string_literal: true

require 'open3'

# PDFを、ページ画像と座標付きテキストに直す。Ghostscript(gs)を呼ぶのはここだけにする。
# PDFの中身(授業時間配当表か、便覧か)は知らない。読み解くのは呼び出し側。
module PdfPages
  class Error < StandardError; end

  # 画面での既定の見え方(幅に合わせる)から拡大しても荒れない程度の解像度。
  DPI = 150
  GS_OPTIONS = %w[-q -dNOPAUSE -dBATCH -dSAFER].freeze

  # dir を作り直して p1.png から順に書き、作ったページ数を返す。
  def self.render(pdf_path, dir)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    _, status = Open3.capture2('gs', *GS_OPTIONS, '-sDEVICE=png16m', "-r#{DPI}",
                               "-sOutputFile=#{File.join(dir, 'p%d.png')}", pdf_path)
    raise Error, 'Ghostscript(gs)でPDFを画像にできませんでした。' unless status.success?

    Dir.glob(File.join(dir, 'p*.png')).size
  rescue Errno::ENOENT
    raise Error, 'Ghostscript(gs)が見つかりません。'
  end

  # PNGの見出し(IHDR)にある横幅。画面はこの実寸をもとに倍率を決める。
  def self.width(path)
    header = File.binread(path, 24)
    header[16, 4]&.unpack1('N') if header.to_s.start_with?("\x89PNG".b)
  end

  # 全ページの文字を、1文字ずつ座標の付いたXMLで返す。ページは <page> で区切られる。
  def self.text_xml(pdf_path)
    xml, status = Open3.capture2('gs', *GS_OPTIONS, '-sDEVICE=txtwrite', '-dTextFormat=0', '-sOutputFile=-', pdf_path)
    raise Error, 'Ghostscript(gs)でPDFを読み取れませんでした。gsが入っているか確認してください。' unless status.success?

    xml.force_encoding(Encoding::UTF_8)
  rescue Errno::ENOENT
    raise Error, 'Ghostscript(gs)が見つかりません。brew install ghostscript などで導入してください。'
  end
end

