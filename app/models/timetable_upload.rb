# frozen_string_literal: true

# アップロードされたPDF1ファイルぶんの取り込み作業。保存が済んだら削除する。
class TimetableUpload < ApplicationRecord
  has_many :rows, -> { order(:position) }, class_name: 'TimetableUploadRow', dependent: :destroy,
                                           inverse_of: :timetable_upload

  validates :semester, inclusion: { in: TimetableImport::Values::SEMESTERS }

  def self.build_from_pdf(pdf_path, semester:, filename:)
    xml = TimetableImport::PdfParser.extract_xml(pdf_path)
    parsed = TimetableImport::PdfParser.new(xml, semester: semester).rows
    raise TimetableImport::PdfParser::Error, 'PDFから科目の行を見つけられませんでした。授業時間配当表のPDFか確認してください。' if parsed.empty?

    transaction do
      import = create!(semester: semester, source_filename: filename)
      parsed.each_with_index { |row, index| import.rows.create!(TimetableUploadRow.attributes_from_parsed(row, index)) }
      import
    end
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
end

