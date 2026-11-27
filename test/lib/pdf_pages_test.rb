# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# gs は動かさない。Open3 を差し替えて、成功・失敗・gs が無いときの振る舞いを見る。
class PdfPagesTest < ActiveSupport::TestCase
  Status = Struct.new(:success?)

  def png_header(width)
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR".b + [width, 100].pack('N2')
  end

  test 'width reads the pixel width from the PNG header' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'p1.png')
      File.binwrite(path, png_header(2113))

      assert_equal 2113, PdfPages.width(path)
    end
  end

  test 'width is nil for a file that is not a PNG' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'p1.png')
      File.binwrite(path, 'not a png')

      assert_nil PdfPages.width(path)
    end
  end

  test 'render recreates the folder and returns the number of pages written' do
    Dir.mktmpdir do |root|
      dir = File.join(root, 'pages')
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'p9.png'), 'stale')
      fake_gs = ->(*args) do
        output = args.find { |arg| arg.start_with?('-sOutputFile=') }.delete_prefix('-sOutputFile=')
        2.times { |index| File.write(output.sub('%d', (index + 1).to_s), 'png') }
        ['', Status.new(true)]
      end

      Open3.stub(:capture2, fake_gs) do
        assert_equal 2, PdfPages.render('in.pdf', dir)
      end
      assert_equal %w[p1.png p2.png], Dir.children(dir).sort
    end
  end

  test 'render raises when gs fails' do
    Dir.mktmpdir do |dir|
      Open3.stub(:capture2, ['', Status.new(false)]) do
        assert_raises(PdfPages::Error) { PdfPages.render('in.pdf', dir) }
      end
    end
  end

  test 'text_xml returns the gs output as UTF-8' do
    Open3.stub(:capture2, ['<page>演習</page>'.b, Status.new(true)]) do
      xml = PdfPages.text_xml('in.pdf')

      assert_equal Encoding::UTF_8, xml.encoding
      assert_equal '<page>演習</page>', xml
    end
  end

  test 'text_xml raises when gs fails' do
    Open3.stub(:capture2, ['', Status.new(false)]) do
      assert_raises(PdfPages::Error) { PdfPages.text_xml('in.pdf') }
    end
  end

  test 'both raise a readable error when gs is not installed' do
    missing = ->(*) { raise Errno::ENOENT, 'gs' }

    Open3.stub(:capture2, missing) do
      Dir.mktmpdir do |dir|
        error = assert_raises(PdfPages::Error) { PdfPages.render('in.pdf', dir) }
        assert_match 'Ghostscript(gs)が見つかりません', error.message
      end
      assert_match 'Ghostscript(gs)が見つかりません', assert_raises(PdfPages::Error) { PdfPages.text_xml('in.pdf') }.message
    end
  end
end

