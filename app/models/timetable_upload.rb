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
      parsed.each_with_index do |row, index|
        upload_row = import.rows.build(TimetableUploadRow.attributes_from_parsed(row, index))
        upload_row.assign_default_course_choice
        upload_row.save!
      end
      import
    end
  end

  EditResult = Struct.new(:updated, :failures, keyword_init: true)

  # 画面の1ページぶんの編集内容とチェックを、まとめて保存する。
  # edits: { 行ID(文字列) => 入力値 } / confirmed_ids: チェックされた行ID(文字列)の配列。
  # remembered: ほかのページでチェックを入れ外ししたまま更新していない行({ 行ID(文字列) => true/false })。
  #   画面にない行なので、入力値は変えず、確認済みかどうかだけを反映する。
  # confirm_valid: 読み取りで要確認が付かず、値にも問題のない行を、全ページぶん確認済みにする。
  # 確認済みにできない行(値に問題がある)は確認済みにせず、その理由を failures({ 行ID => 理由の配列 })で返す。
  def apply_edits(edits, confirmed_ids, confirm_valid: false, remembered: {})
    result = EditResult.new(updated: 0, failures: {})
    transaction do
      rows.each do |row|
        id = row.id.to_s
        values = edits[id]
        next if values.nil? && !remembered.key?(id) && !confirm_valid

        row.apply_edit(values) if values
        update_confirmation(row, checked_state(row, values, confirmed_ids, remembered), confirm_valid, result)
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

  # 画面から送られたページの行はチェックの有無、覚えていた行は覚えていた状態、それ以外は今の状態
  def checked_state(row, values, confirmed_ids, remembered)
    id = row.id.to_s
    return confirmed_ids.include?(id) if values
    return remembered[id] if remembered.key?(id)

    row.confirmed
  end

  def update_confirmation(row, checked, confirm_valid, result)
    checked ||= confirm_valid && row.review_reason.blank? && row.problems.empty?
    problems = checked ? row.problems : []
    result.failures[row.id.to_s] = problems if problems.any?
    row.confirmed = checked && problems.empty?
  end
end

