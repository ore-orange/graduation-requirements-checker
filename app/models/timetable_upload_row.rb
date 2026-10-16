# frozen_string_literal: true

class TimetableUploadRow < ApplicationRecord
  EDITABLE = %i[lecture_code course_number name credits requirement_type grade_text weekday period_text
                term_type].freeze

  belongs_to :timetable_upload

  # PDF解析の出力(日本語の見出しをキーにしたハッシュ)から列の値を作る
  def self.attributes_from_parsed(row, index)
    { position: index, lecture_code: row['講義コード'], course_number: row['科目番号'], name: row['科目名'],
      credits: row['単位'], requirement_type: row['必修選択'], grade_text: row['受講年次'], weekday: row['曜日'],
      period_text: row['時限'], term_type: row['開講区分'], note: row['備考'], review_reason: row['要確認'].presence }
  end

  def importer_values(review: '')
    { '要確認' => review, '学期' => timetable_upload.semester, '講義コード' => lecture_code.to_s,
      '科目番号' => course_number.to_s, '科目名' => name.to_s, '単位' => credits.to_s,
      '必修選択' => requirement_type.to_s, '受講年次' => grade_text.to_s, '曜日' => weekday.to_s,
      '時限' => period_text.to_s, '開講区分' => term_type.to_s, '備考' => note.to_s }
  end

  # Importerに渡す行。確認済みでなければ「要確認」を残し、保存対象にしない。
  def importer_row
    importer_values(review: confirmed ? '' : (review_reason.presence || '未確認'))
  end

  # 今の値がDBに入れられる形か(確認済みにしてよいか)。問題があればその一覧を返す。
  def problems
    TimetableImport::Importer::RowAttributes.new(importer_values).errors
  end
end

