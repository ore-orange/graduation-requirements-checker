# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# gs は動かさない。PdfPages を差し替えて、ページの指定と下書きの作り方を見る。
class RequirementsUploadTest < ActiveSupport::TestCase
  def upload(page_range, count: 14, render: nil)
    render ||= ->(_pdf, _page, path) do
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, 'png')
      path
    end
    PdfPages.stub(:page_count, count) do
      PdfPages.stub(:render_page, render) do
        PdfPages.stub(:page_text, ->(_pdf, page) { "#{page}ページの文字" }) do
          CurriculumImport::RequirementsUpload.call(pdf_path: 'in.pdf', filename: 'binran.pdf', slug: 'test_program',
                                                    admission_year: 2025, page_range: page_range)
        end
      end
    end
  end

  test '指定したページの画像と文字を取り、未読の下書きを作る' do
    draft = upload('10-11')

    assert_not draft.published?
    assert_equal 'binran.pdf', draft.source_filename
    assert_equal [{ 'page' => 10, 'text' => '10ページの文字', 'status' => 'pending', 'error' => nil },
                  { 'page' => 11, 'text' => '11ページの文字', 'status' => 'pending', 'error' => nil }], draft.pages
    assert_predicate draft.page_image_path(11), :present?
    assert_nil draft.page_image_path(12)
  end

  test '1ページだけ、全角の数字や波線でも指定できる' do
    assert_equal [11], upload('１１').pages.pluck('page')
    assert_equal [10, 11, 12], upload('10〜12').pages.pluck('page')
  end

  test '読めない指定・範囲外・多すぎる指定は、下書きを作らずに断る' do
    ['', 'abc', '12-10', '0', '14-15', '1-11'].each do |range|
      assert_no_difference('Curriculum.count', range) do
        assert_raises(CurriculumImport::RequirementsUpload::Error, range) { upload(range) }
      end
    end
  end

  test '途中で画像を作れなければ、作りかけの下書きと画像を残さない' do
    failing = ->(*) { raise PdfPages::Error, '11ページを画像にできませんでした。' }

    assert_no_difference('Curriculum.count') do
      error = assert_raises(CurriculumImport::RequirementsUpload::Error) { upload('11', render: failing) }
      assert_match '11ページ', error.message
    end
  end

  test '下書きを消すと、ページ画像も消える' do
    draft = upload('11')
    dir = draft.images_dir

    draft.destroy

    assert_not dir.exist?
  end
end

