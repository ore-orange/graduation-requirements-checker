# frozen_string_literal: true

# アップロードされたPDF1ファイルぶんの取り込み作業。保存が済んだら削除する。
class TimetableUpload < ApplicationRecord
  has_many :rows, -> { order(:position) }, class_name: 'TimetableUploadRow', dependent: :destroy,
                                           inverse_of: :timetable_upload

  validates :semester, inclusion: { in: TimetableImport::Values::SEMESTERS }

  # 見比べ用のページ画像の置き場。取り込みを消すときに、ここごと消す。
  after_destroy { FileUtils.rm_rf(images_dir) }

  def self.build_from_pdf(pdf_path, semester:, filename:)
    xml = TimetableImport::PdfParser.extract_xml(pdf_path)
    parsed = TimetableImport::PdfParser.new(xml, semester: semester).rows
    raise TimetableImport::PdfParser::Error, 'PDFから科目の行を見つけられませんでした。授業時間配当表のPDFか確認してください。' if parsed.empty?

    import = transaction do
      import = create!(semester: semester, source_filename: filename)
      parsed.each_with_index do |row, index|
        upload_row = import.rows.build(TimetableUploadRow.attributes_from_parsed(row, index))
        upload_row.assign_default_course_choice
        upload_row.save!
      end
      import
    end
    import.render_page_images(pdf_path)
    import
  end

  def images_dir
    Rails.root.join('storage/timetable_uploads', id.to_s)
  end

  def page_count
    Dir.glob(images_dir.join('p*.png')).size
  end

  # 画面に出すページ画像。無ければ nil。
  def page_image_path(page)
    path = images_dir.join("p#{Integer(page.to_s, 10, exception: false) || 0}.png")
    path if File.exist?(path)
  end

  # 見比べ用の画像を作る。作れなくても取り込みは成立させる(ペインが出ないだけ)。
  def render_page_images(pdf_path)
    TimetableImport::PageImages.render(pdf_path, images_dir)
  rescue TimetableImport::PageImages::Error
    nil
  end

  EditResult = Struct.new(:updated, :failures, keyword_init: true)

  # 画面から送られた編集内容とチェックを、まとめて保存する。
  # edits: { 行ID(文字列) => 入力値 } / confirmed_ids: チェックされた行ID(文字列)の配列。
  # confirm_valid: 読み取りで要確認が付かず、値にも問題のない行を、まとめて確認済みにする。
  # 確認済みにできない行(値に問題がある)は確認済みにせず、その理由を failures({ 行ID => 理由の配列 })で返す。
  def apply_edits(edits, confirmed_ids, confirm_valid: false)
    result = EditResult.new(updated: 0, failures: {})
    transaction do
      rows.each do |row|
        values = edits[row.id.to_s]
        next if values.nil? && !confirm_valid

        row.apply_edit(values) if values
        update_confirmation(row, checked_state(row, values, confirmed_ids), confirm_valid, result)
        next unless row.changed?

        row.save!
        result.updated += 1
      end
    end
    result
  end

  def unconfirmed_count
    rows.count { |row| !row.confirmed }
  end

  def all_confirmed?
    rows.any? && unconfirmed_count.zero?
  end

  # 取り込み前の件数・エラーの確認(DBは変更しない)
  def preview
    TimetableImport::Importer.new(rows.map(&:importer_row)).call
  end

  # 全行が確認済みのときだけ保存する。エラーがあれば何も保存しない。
  def commit!
    return nil unless all_confirmed?

    result = TimetableImport::Importer.new(rows.map(&:importer_row)).call(apply: true)
    destroy! if result.applied
    result
  end

  private

  # 画面から送られた行はチェックの有無、それ以外は今の状態
  def checked_state(row, values, confirmed_ids)
    values ? confirmed_ids.include?(row.id.to_s) : row.confirmed
  end

  def update_confirmation(row, checked, confirm_valid, result)
    checked ||= confirm_valid && row.review_reason.blank? && row.problems.empty?
    problems = checked ? row.problems : []
    result.failures[row.id.to_s] = problems if problems.any?
    row.confirmed = checked && problems.empty?
  end
end

