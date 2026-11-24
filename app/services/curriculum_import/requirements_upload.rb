# frozen_string_literal: true

module CurriculumImport
  # 便覧PDFの要件表のページから、読み取り前の下書き(公開していない Curriculum)を作る。
  # 指定したページだけを画像とテキストにして残し、PDFは保管しない(あとから取り直せないので、ここで全部取る)。
  class RequirementsUpload
    # 人が直せる理由。メッセージはそのまま画面に出す。
    class Error < StandardError; end

    # 要件表は数ページに収まる。桁違いの範囲で、画像を大量に作らないため。
    MAX_PAGES = 10
    RANGE_FORMAT = /\A\s*(\d{1,4})\s*(?:[-〜~ー－]\s*(\d{1,4})\s*)?\z/

    def self.call(...) = new(...).call

    # page_range は「11」や「10-12」。
    def initialize(pdf_path:, filename:, slug:, admission_year:, page_range:)
      @pdf_path = pdf_path
      @filename = filename
      @slug = slug
      @admission_year = admission_year
      @page_range = page_range
    end

    def call
      numbers = pages(PdfPages.page_count(@pdf_path))
      curriculum = Curriculum.create!(slug: @slug, admission_year: @admission_year, document: {},
                                      source_filename: @filename, pages: [])
      begin
        curriculum.update!(pages: numbers.map { |number| extract(curriculum, number) })
      rescue StandardError
        # 途中で失敗した下書きは残さない(ページ画像ごと消す)。
        curriculum.destroy
        raise
      end
      curriculum
    rescue PdfPages::Error => e
      # Ghostscript の失敗などの詳しい理由はログへ。画面には、事務の方ができることを伝える。
      Rails.logger.warn("便覧PDFの取り込みに失敗しました: #{e.message}")
      raise Error, 'PDFを読み込めませんでした。PDFが壊れていないか確かめて、もう一度取り込んでください。'
    end

    private

    def pages(count)
      match = RANGE_FORMAT.match(@page_range.to_s.tr('０-９', '0-9'))
      raise Error, 'ページは「11」や「10-12」のように指定してください。' unless match

      first = match[1].to_i
      last = (match[2] || match[1]).to_i
      raise Error, "ページは1〜#{count}の範囲で、小さい順に指定してください。" unless first.between?(1, last) && last <= count
      raise Error, "一度に読み込めるのは#{MAX_PAGES}ページまでです。" if last - first + 1 > MAX_PAGES

      (first..last).to_a
    end

    def extract(curriculum, number)
      PdfPages.render_page(@pdf_path, number, curriculum.images_dir.join("p#{number}.png"))
      { 'page' => number, 'text' => PdfPages.page_text(@pdf_path, number), 'status' => 'pending', 'error' => nil }
    end
  end
end

