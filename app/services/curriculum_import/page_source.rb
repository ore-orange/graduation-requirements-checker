# frozen_string_literal: true

require 'tmpdir'

module CurriculumImport
  # 便覧PDFから、AIに読ませる材料(ページ画像とページごとのテキスト)を取り出す。
  # 便覧の表は2段組で見出しが縦書きなので、テキストだけでは順序が崩れ、画像だけでは細かい注記を落とす。両方を作る。
  # PDFは保管しないので、これを呼べるのはアップロードを受けたときだけ。Ghostscript(gs)は時間付きで呼び、止まらせない。
  module PageSource
    class Error < StandardError; end
    class PageCountError < Error; end

    # extract の結果。page_count が 0 のときは数えられなかった(texts は空)。
    Result = Struct.new(:page_count, :texts, :errors, keyword_init: true)
    # failed_pages は、gs が失敗したページ(1始まり)。本当に空白のページは含まない。
    TextResult = Struct.new(:texts, :failed_pages)

    DPI = 150
    COUNT_TIMEOUT = 30
    RENDER_TIMEOUT = 180
    TEXT_PAGE_TIMEOUT = 30
    TEXT_TOTAL_TIMEOUT = 120
    GS_OPTIONS = %w[-q -dNOPAUSE -dBATCH -dSAFER].freeze

    class << self
      # PDFのページ数。数えられない・多すぎるときは PageCountError。
      def page_count(pdf_path)
        out, err, status = GsRunner.run('gs', '-q', '-dNODISPLAY', '-dNOPAUSE', '-dBATCH', '-dSAFER',
                                        "--permit-file-read=#{pdf_path}", "-sInput=#{pdf_path}",
                                        '-c', 'Input (r) file runpdfbegin pdfpagecount = quit', timeout: COUNT_TIMEOUT)
        count = Integer(out.to_s.strip, 10, exception: false)
        unless status.success? && count&.positive?
          Rails.logger.warn("ページ数を数えられませんでした: #{err.to_s.lines.first(3).join.strip}")
          raise PageCountError, 'PDFのページ数を数えられませんでした。壊れたPDFか確認してください。'
        end
        raise PageCountError, "ページ数が多すぎます（#{count}ページ）。" if count > Curriculum::MAX_PAGES

        count
      rescue Errno::ENOENT
        raise PageCountError, 'Ghostscript(gs)が見つかりません。'
      rescue GsRunner::TimeoutError
        raise PageCountError, 'PDFのページ数を数える途中で時間切れになりました。'
      end

      # dir を作り直し、p1.png から順に書いて、できた画像の枚数を返す。
      # gs が失敗しても例外にはしない(取り込みを止めない)。できた分だけ残し、足りないかどうかは呼び出し側が枚数で見る。
      def render_images(pdf_path, dir)
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        begin
          output = File.join(dir, 'p%d.png')
          _out, err, status = GsRunner.run('gs', *GS_OPTIONS, '-sDEVICE=png16m', "-r#{DPI}", "-sOutputFile=#{output}",
                                           pdf_path.to_s, timeout: RENDER_TIMEOUT)
          Rails.logger.warn("ページ画像を作れませんでした: #{err.to_s.lines.first(3).join.strip}") unless status.success?
        rescue Errno::ENOENT, GsRunner::TimeoutError => e
          Rails.logger.warn("ページ画像を作れませんでした: #{e.class}")
        end
        PngFiles.keep_complete(dir)
      end

      # ページごとのテキスト。ページ順に1要素ずつ返す。読めないページは空文字で、後ろのページはずらさない。
      # ページ数が分からず、数えられないときは空の配列。
      def page_texts(pdf_path, page_count: nil)
        page_count ||= self.page_count(pdf_path)
        extract_texts(pdf_path, page_count).texts
      rescue PageCountError
        []
      end

      def extract_texts(pdf_path, page_count)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TEXT_TOTAL_TIMEOUT
        failed = []
        texts = Array.new(page_count) do |index|
          page_text(pdf_path, index + 1, deadline) || ''.tap { failed << (index + 1) }
        end
        TextResult.new(texts, failed)
      end

      # アップロードされたPDFから、ページ数・画像(images_dir)・テキストをまとめて取り出す。
      # どの段階が失敗しても例外にせず、取れた分と、何が取れなかったかを返す。
      def extract(pdf_path, images_dir)
        count = page_count(pdf_path)
        errors = [render_error(pdf_path, images_dir, count)]
        texts = read_texts(pdf_path, count, errors)
        Result.new(page_count: count, texts: texts, errors: errors.compact)
      rescue PageCountError => e
        Result.new(page_count: 0, texts: [], errors: [e.message])
      end

      private

      def page_text(pdf_path, page, deadline)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if remaining <= 0

        Dir.mktmpdir('page_text') do |dir|
          output = File.join(dir, 'text.txt')
          _out, err, status = GsRunner.run('gs', *GS_OPTIONS, '-sDEVICE=txtwrite', '-dTextFormat=3',
                                           "-dFirstPage=#{page}", "-dLastPage=#{page}", "-sOutputFile=#{output}",
                                           pdf_path.to_s, timeout: [TEXT_PAGE_TIMEOUT, remaining].min)
          # gs は壊れたPDFでも終了状態を成功にし、エラー文を標準出力へ書く。本文として取り違えないよう、ファイルへ出させ、
          # 書き出されたか(空白のページでも空のファイルはできる)で成否を見る。
          return PageText.tidy(File.binread(output)) if status.success? && File.file?(output)

          Rails.logger.warn("#{page}ページの文字を取り出せませんでした: #{err.to_s.lines.first(3).join.strip}")
          nil
        end
      rescue Errno::ENOENT, GsRunner::TimeoutError => e
        Rails.logger.warn("#{page}ページの文字を取り出せませんでした: #{e.class}")
        nil
      end

      # 画像が揃わなかった理由。揃ったなら nil。
      def render_error(pdf_path, images_dir, count)
        rendered = render_images(pdf_path, images_dir)
        "ページ画像を#{count}ページ中#{rendered}ページしか作れませんでした。" if rendered < count
      rescue StandardError => e
        Rails.logger.warn("ページ画像を作れませんでした: #{e.class}: #{e.message}")
        'ページ画像を作れませんでした。'
      end

      # ページごとのテキスト。読めなかったページがあれば、その番号を errors に足す。
      def read_texts(pdf_path, count, errors)
        result = extract_texts(pdf_path, count)
        errors << "#{result.failed_pages.join('・')}ページの文字を取り出せませんでした。" if result.failed_pages.any?
        result.texts
      rescue StandardError => e
        Rails.logger.warn("文字を取り出せませんでした: #{e.class}: #{e.message}")
        errors << '文字を取り出せませんでした。'
        Array.new(count, '')
      end
    end
  end
end

