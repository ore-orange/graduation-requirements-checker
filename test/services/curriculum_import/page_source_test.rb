# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tmpdir'

module CurriculumImport
  class PageSourceTest < ActiveSupport::TestCase
    PageSource = CurriculumImport::PageSource
    REAL_PDF = Rails.root.join('docs/kogaku_chinot_y24.pdf')
    PNG_MAGIC = "\x89PNG".b

    setup do
      @tmp = Pathname.new(Dir.mktmpdir('page_source'))
      @dir = @tmp.join('images')
    end

    teardown { FileUtils.rm_rf(@tmp) }

    def broken_pdf
      @tmp.join('broken.pdf').tap { |path| path.write("%PDF-1.4\nbroken") }
    end

    test 'ページ数を数える' do
      assert_equal 14, PageSource.page_count(REAL_PDF)
    end

    test '数えられないPDFや存在しないファイルは PageCountError にする' do
      assert_raises(PageSource::PageCountError) { PageSource.page_count(broken_pdf) }
      assert_raises(PageSource::PageCountError) { PageSource.page_count(@tmp.join('none.pdf')) }
    end

    test '上限を超えるページ数は PageCountError にする' do
      stub = ->(*_args, **_opts) { ["#{Curriculum::MAX_PAGES + 1}\n", '', Struct.new(:success?).new(true)] }
      CurriculumImport::GsRunner.stub(:run, stub) do
        error = assert_raises(PageSource::PageCountError) { PageSource.page_count(REAL_PDF) }
        assert_match(/多すぎ/, error.message)
      end
    end

    test 'ページ数ぶんのPNGを p<n>.png で作る' do
      assert_equal 14, PageSource.render_images(REAL_PDF, @dir)

      assert_equal (1..14).map { |n| "p#{n}.png" }.sort, Dir.children(@dir).sort
      assert_equal PNG_MAGIC, File.binread(@dir.join('p1.png'), 4)
      assert_operator TimetableImport::PageImages.width(@dir.join('p1.png').to_s), :>, 1000
    end

    test '画像化し直すと、前の画像は残らない' do
      FileUtils.mkdir_p(@dir)
      @dir.join('p99.png').write('old')

      PageSource.render_images(REAL_PDF, @dir)

      refute_path_exists @dir.join('p99.png')
    end

    test 'gs が失敗しても例外にせず、0を返して画像を残さない' do
      assert_equal 0, PageSource.render_images(Rails.root.join('README.md'), @dir)
      assert_equal 0, PageSource.render_images(broken_pdf, @dir)
      assert_empty Dir.glob(@dir.join('*.png'))
    end

    test 'gs が見つからなくても例外にせず0を返す' do
      CurriculumImport::GsRunner.stub(:run, ->(*_args, **_opts) { raise Errno::ENOENT }) do
        assert_equal 0, PageSource.render_images(REAL_PDF, @dir)
      end
    end

    test '画像化が時間切れになったら、書きかけの画像を残さない' do
      FileUtils.mkdir_p(@dir)
      stub = ->(*_args, **_opts) do
        @dir.join('p1.png').binwrite("\x89PNG\r\n\x1A\n".b + ('x' * 100))
        raise CurriculumImport::GsRunner::TimeoutError
      end
      CurriculumImport::GsRunner.stub(:run, stub) do
        assert_equal 0, PageSource.render_images(REAL_PDF, @dir)
      end
    end

    test 'ページごとのテキストを、ページの順に1要素ずつ返す' do
      texts = PageSource.page_texts(REAL_PDF)

      assert_equal 14, texts.size
      assert_includes texts.first, '知能情報コース'
      assert_includes texts[2], '工学基礎演習'
      assert_not_includes texts[2], '知能情報コース提供の科目'
    end

    test 'テキストは余白の空白や空行で膨らませない' do
      texts = PageSource.page_texts(REAL_PDF)

      assert_operator texts.sum(&:bytesize), :<, 200_000
      texts.each do |text|
        assert_no_match(/ {3}/, text)
        assert_no_match(/\n\n/, text)
        assert_no_match(/[\u0000-\u0008\u000B-\u001F]/, text)
      end
    end

    test 'ページ数を渡せば、数え直さない' do
      PageSource.stub(:page_count, ->(*) { flunk '数え直した' }) do
        assert_equal 14, PageSource.page_texts(REAL_PDF, page_count: 14).size
      end
    end

    test '読めないPDFは、ページ数が分かれば、その数だけ空文字を返す(後ろのページがずれない)' do
      assert_equal ['', '', ''], PageSource.page_texts(broken_pdf, page_count: 3)
      assert_empty PageSource.page_texts(broken_pdf)
    end

    test '空白のページは、失敗ではなく空文字として返す' do
      blank = @tmp.join('blank.pdf')
      system('gs', '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=pdfwrite', "-sOutputFile=#{blank}",
             '-c', 'showpage', exception: true)

      result = PageSource.extract_texts(blank, 1)

      assert_equal [''], result.texts
      assert_empty result.failed_pages
    end

    test '範囲外のページは、gsのエラー文を本文にせず失敗として返す' do
      result = PageSource.extract_texts(REAL_PDF, 16)

      assert_equal 16, result.texts.size
      assert_equal [15, 16], result.failed_pages
      assert_equal ['', ''], result.texts.last(2)
    end

    test '読めなかったページだけ空文字にして、失敗したページ番号を返す' do
      real = CurriculumImport::GsRunner.method(:run)
      failing_page = 4
      stub = ->(*command, **opts) do
        next ['', 'boom', Struct.new(:success?).new(false)] if command.include?("-dFirstPage=#{failing_page}")

        real.call(*command, **opts)
      end
      CurriculumImport::GsRunner.stub(:run, stub) do
        result = PageSource.extract_texts(REAL_PDF, 14)

        assert_equal 14, result.texts.size
        assert_equal '', result.texts[failing_page - 1]
        assert_includes result.texts[2], '工学基礎演習'
        assert_equal [failing_page], result.failed_pages
      end
    end

    test '全体の時間を超えたら、残りのページは空文字にして失敗として返す' do
      CurriculumImport::GsRunner.stub(:run, ->(*_args, **_opts) { raise CurriculumImport::GsRunner::TimeoutError }) do
        result = PageSource.extract_texts(REAL_PDF, 3)

        assert_equal ['', '', ''], result.texts
        assert_equal [1, 2, 3], result.failed_pages
      end
    end

    test '子プロセスは、時間を超えたら止める' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(CurriculumImport::GsRunner::TimeoutError) { CurriculumImport::GsRunner.run('sleep', '30', timeout: 0.3) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end

    test '子プロセスの標準出力と終了状態を返す' do
      out, _err, status = CurriculumImport::GsRunner.run('echo', 'こんにちは', timeout: 5)
      assert_equal "こんにちは\n", out.force_encoding('UTF-8')
      assert_predicate status, :success?
    end

    test 'extract は、ページ数・画像・テキストをまとめて取り出す' do
      result = PageSource.extract(REAL_PDF, @dir)

      assert_equal 14, result.page_count
      assert_equal 14, result.texts.size
      assert_empty result.errors
      assert_equal 14, Dir.glob(@dir.join('p*.png')).size
    end

    test 'extract は、ページ数を数えられなければ、画像もテキストも作らずに理由を返す' do
      result = PageSource.extract(broken_pdf, @dir)

      assert_equal 0, result.page_count
      assert_empty result.texts
      assert_equal 1, result.errors.size
      refute_path_exists @dir
    end

    test 'extract は、画像が足りなければ理由を返し、テキストは取り出す' do
      PageSource.stub(:render_images, ->(*) { 10 }) do
        result = PageSource.extract(REAL_PDF, @dir)

        assert_equal 14, result.page_count
        assert_equal 14, result.texts.size
        assert_equal 1, result.errors.size
        assert_match(/14ページ中10ページ/, result.errors.first)
      end
    end

    test 'extract は、画像化が例外を出しても、テキストまで進んで理由を返す' do
      PageSource.stub(:render_images, ->(*) { raise IOError, 'disk' }) do
        result = PageSource.extract(REAL_PDF, @dir)

        assert_equal 14, result.page_count
        assert_equal 14, result.texts.size
        assert_equal 1, result.errors.size
      end
    end

    test 'extract は、読めなかったページを理由に含める' do
      failed = PageSource::TextResult.new(['a', '', 'c'], [2])
      PageSource.stub(:page_count, 3) do
        PageSource.stub(:render_images, 3) do
          PageSource.stub(:extract_texts, failed) do
            result = PageSource.extract(REAL_PDF, @dir)

            assert_equal ['a', '', 'c'], result.texts
            assert_match(/2ページ/, result.errors.join)
          end
        end
      end
    end
  end
end

