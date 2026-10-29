# frozen_string_literal: true

module CurriculumImport
  # gs が書いたPNGの置き場の後始末。
  module PngFiles
    IEND = "IEND\xAEB`\x82".b

    # 書きかけで止まった画像(時間切れや異常終了)はPNGの終端が無いので消し、完全な画像の枚数を返す。1枚も無ければ dir ごと消す。
    def self.keep_complete(dir)
      complete, partial = Dir.glob(File.join(dir, 'p*.png')).partition { |path| complete?(path) }
      FileUtils.rm_f(partial)
      FileUtils.rm_rf(dir) if complete.empty?
      complete.size
    end

    def self.complete?(path)
      size = File.size(path)
      size > IEND.bytesize && File.binread(path, IEND.bytesize, size - IEND.bytesize) == IEND
    end
  end
end

