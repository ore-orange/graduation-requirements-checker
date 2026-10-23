# frozen_string_literal: true

require 'open3'

module TimetableImport
  # 取り込んだPDFのページを、見比べ用の画像にする。解析と同じGhostscriptを使う。
  module PageImages
    class Error < StandardError; end

    # 画面での既定の見え方(幅に合わせる)から拡大しても荒れない程度の解像度。
    DPI = 150

    # dir を作り直して p1.png から順に書き、作ったページ数を返す。
    def self.render(pdf_path, dir)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      _, status = Open3.capture2('gs', '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=png16m',
                                 "-r#{DPI}", "-sOutputFile=#{File.join(dir, 'p%d.png')}", pdf_path)
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
  end
end

