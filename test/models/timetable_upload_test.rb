# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class TimetableUploadTest < ActiveSupport::TestCase
  # gsの出力と同じ形の座標付きXML。1科目ぶん。
  XML = <<~XML
    <page>
    <span bbox="64 153 109 153" font="F" size="10"><char bbox="64 153 65 153" c="6"/><char bbox="69 153 70 153" c="1"/><char bbox="74 153 75 153" c="0"/><char bbox="79 153 80 153" c="0"/><char bbox="84 153 85 153" c="0"/><char bbox="89 153 90 153" c="0"/><char bbox="94 153 95 153" c="0"/><char bbox="99 153 100 153" c="7"/><char bbox="104 153 105 153" c="1"/></span>
    <span bbox="167 153 197 153" font="F" size="10"><char bbox="167 153 168 153" c="演"/><char bbox="172 153 173 153" c="習"/></span>
    </page>
  XML

  def build_upload(renderer)
    TimetableImport::PdfParser.stub(:extract_xml, XML) do
      TimetableImport::PageImages.stub(:render, renderer) do
        TimetableUpload.build_from_pdf('dummy.pdf', semester: '前期', filename: 'a.pdf')
      end
    end
  end

  # 幅2113pxのPNGの見出し(IHDR)だけを持つファイル。幅の読み取りに使う。
  def png_header(width)
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR".b + [width, 100].pack('N2')
  end

  def write_one_page(_pdf, dir)
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, 'p1.png'), png_header(2113))
    1
  end

  test 'build_from_pdf renders page images into the upload folder' do
    upload = build_upload(method(:write_one_page))

    assert_equal 1, upload.page_count
    assert_equal 2113, upload.page_width
    assert_equal png_header(2113), File.binread(upload.page_image_path(1))
    assert_nil upload.page_image_path(2)
  end

  test 'an upload still works when the pages cannot be rendered' do
    upload = build_upload(->(_pdf, _dir) { raise TimetableImport::PageImages::Error, 'gsが見つかりません' })

    assert_equal 1, upload.rows.size
    assert_equal 0, upload.page_count
    assert_nil upload.page_width
  end

  test 'page images live under the images root, which is set per environment and per test worker' do
    upload = build_upload(method(:write_one_page))

    assert_equal TimetableUpload.images_root.join(upload.id.to_s).to_s, upload.images_dir.to_s
    assert_not_includes TimetableUpload.images_root.to_s, 'storage/timetable_uploads'
  end

  test 'an upload still works when the image folder cannot be written' do
    upload = build_upload(->(_pdf, _dir) { raise Errno::EACCES, '/app/storage' })

    assert_equal 1, upload.rows.size
    assert_equal 0, upload.page_count
  end

  test 'destroying an upload removes its page images' do
    upload = build_upload(method(:write_one_page))
    dir = upload.images_dir

    assert_path_exists dir
    upload.destroy!
    assert_not File.exist?(dir)
  end
end

