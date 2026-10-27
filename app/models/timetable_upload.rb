# frozen_string_literal: true

# アップロードされたPDF1ファイルぶんの取り込み作業。保存が済んだら削除する。
class TimetableUpload < ApplicationRecord
  has_many :rows, -> { order(:position) }, class_name: 'TimetableUploadRow', dependent: :destroy,
                                           inverse_of: :timetable_upload
  belongs_to :department

  validates :semester, inclusion: { in: TimetableImport::Values::SEMESTERS }

  # 見比べ用のページ画像の置き場。取り込みを消すときに、ここごと消す。
  after_destroy { FileUtils.rm_rf(images_dir) }

  class << self
    # ページ画像の置き場の根。環境ごとに分ける(テストが開発用の画像を消さないように)。
    # テストでは、並列の実行ごとに別の場所を割り当てる。
    attr_writer :images_root

    def images_root
      @images_root ||= Rails.root.join('storage/timetable_uploads', Rails.env)
    end
  end

  def self.build_from_pdf(pdf_path, semester:, year:, department_id:, filename:)
    xml = TimetableImport::PdfParser.extract_xml(pdf_path)
    parsed = TimetableImport::PdfParser.new(xml, semester: semester).rows
    raise TimetableImport::PdfParser::Error, 'PDFから科目の行を見つけられませんでした。授業時間配当表のPDFか確認してください。' if parsed.empty?

    import = transaction do
      import = create!(semester: semester, year: year, department_id: department_id, source_filename: filename)
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
    self.class.images_root.join(id.to_s)
  end

  def page_count
    page_image_paths.size
  end

  # 実際にあるページ画像をページ順に並べたもの。画面に出すのはこの中のものだけ。
  def page_image_paths
    @page_image_paths ||= Dir.glob(images_dir.join('p*.png')).sort_by { |path| File.basename(path)[/\d+/].to_i }
  end

  # 画面に出すページ画像。1始まりのページ番号で引く。無ければ nil。
  def page_image_path(page)
    number = Integer(page.to_s, 10, exception: false)
    return unless number&.positive?

    page_image_paths[number - 1]
  end

  # ページ画像の実寸(横幅px)。画面の倍率はこれをもとに決める。
  def page_width
    first = page_image_paths.first
    TimetableImport::PageImages.width(first) if first
  end

  # ページ画像の中身。画面には、この取り込みが実際に作った画像しか出さない。
  def page_image_data(page)
    path = page_image_path(page)
    File.binread(path) if path
  end

  # 見比べ用の画像を作る。作れなくても取り込みは成立させる(ペインが出ないだけ)。
  def render_page_images(pdf_path)
    TimetableImport::PageImages.render(pdf_path, images_dir)
  rescue StandardError => e
    Rails.logger.warn("ページ画像を作れませんでした(取り込みは続けます): #{e.class}: #{e.message}")
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

  # PDFにあるのに読み取れなかった科目を、指定した行の次に足す。
  # 行が見つからなければ末尾に足す。後ろの行は1つずつ下げる。
  def add_row_after(row_id)
    after = rows.find_by(id: row_id)
    position = after ? after.position + 1 : rows.maximum(:position).to_i + 1
    transaction do
      rows.where(position: position..).reorder(position: :desc).each { |row| row.update!(position: row.position + 1) }
      rows.create!(position: position, added_by_hand: true)
    end
  end

  def unconfirmed_count
    rows.count { |row| !row.confirmed }
  end

  def all_confirmed?
    rows.any? && unconfirmed_count.zero?
  end

  # 「2026年度 工学部 工学科 前期」。何を取り込んでいるかを画面に出すため。
  def classification_label
    "#{year}年度 #{department.faculty.name} #{department.name} #{semester}"
  end

  # 取り込み前の件数・エラーの確認(DBは変更しない)
  def preview
    importer.call
  end

  # 全行が確認済みのときだけ保存する。エラーがあれば何も保存しない。
  def commit!
    return nil unless all_confirmed?

    result = importer.call(apply: true)
    destroy! if result.applied
    result
  end

  private

  def importer
    TimetableImport::Importer.new(rows.map(&:importer_row), year: year, department_id: department_id)
  end

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

