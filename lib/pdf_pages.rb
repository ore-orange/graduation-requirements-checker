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

  # PDFのページ数。PDFでないファイルでも gs は成功で終わるので、出力が数であることで確かめる。
  def self.page_count(pdf_path)
    out, status = Open3.capture2('gs', '-q', '-dNODISPLAY', '-dNOPAUSE', '-dBATCH', '-dSAFER',
                                 "--permit-file-read=#{pdf_path}", "-sInput=#{pdf_path}",
                                 '-c', 'Input (r) file runpdfbegin pdfpagecount = quit')
    count = Integer(out.to_s.strip, 10, exception: false)
    raise Error, 'PDFのページ数を数えられませんでした。PDFか確認してください。' unless status.success? && count&.positive?

    count
  rescue Errno::ENOENT
    raise Error, 'Ghostscript(gs)が見つかりません。'
  end

  # 1ページだけを画像にして path に書く。page は1始まり。
  def self.render_page(pdf_path, page, path)
    FileUtils.mkdir_p(File.dirname(path))
    _, status = Open3.capture2('gs', *GS_OPTIONS, '-sDEVICE=png16m', "-r#{DPI}", *page_range(page),
                               "-sOutputFile=#{path}", pdf_path)
    raise Error, "#{page}ページを画像にできませんでした。" unless status.success? && File.file?(path)

    path
  rescue Errno::ENOENT
    raise Error, 'Ghostscript(gs)が見つかりません。'
  end

  # 1ページの文字を、行のまとまりを保ったテキストで返す(AIに画像と一緒に渡す補助)。page は1始まり。
  # 便覧のPDFは NUL などの制御文字を含むことがあり、そのままでは DB(jsonb)に入らないので、改行とタブ以外は落とす。
  def self.page_text(pdf_path, page)
    text, status = Open3.capture2('gs', *GS_OPTIONS, '-sDEVICE=txtwrite', '-dTextFormat=3', *page_range(page),
                                  '-sOutputFile=-', pdf_path)
    raise Error, "#{page}ページの文字を取り出せませんでした。" unless status.success?

    text.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/[\x00-\x08\x0B-\x1F\x7F]/, '')
  rescue Errno::ENOENT
    raise Error, 'Ghostscript(gs)が見つかりません。'
  end

  def self.page_range(page)
    ["-dFirstPage=#{Integer(page)}", "-dLastPage=#{Integer(page)}"]
  end
  private_class_method :page_range

  # 全ページの文字を、1文字ずつ座標の付いたXMLで返す。ページは <page> で区切られる。
  def self.text_xml(pdf_path)
    xml, status = Open3.capture2('gs', *GS_OPTIONS, '-sDEVICE=txtwrite', '-dTextFormat=0', '-sOutputFile=-', pdf_path)
    raise Error, 'Ghostscript(gs)でPDFを読み取れませんでした。gsが入っているか確認してください。' unless status.success?

    xml.force_encoding(Encoding::UTF_8)
  rescue Errno::ENOENT
    raise Error, 'Ghostscript(gs)が見つかりません。brew install ghostscript などで導入してください。'
  end
end

