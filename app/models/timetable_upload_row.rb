# frozen_string_literal: true

class TimetableUploadRow < ApplicationRecord
  EDITABLE = %i[lecture_code course_number name credits requirement_type grade_text weekday period_text
                term_type].freeze

  belongs_to :timetable_upload
  belongs_to :course, optional: true

  # PDF解析の出力(日本語の見出しをキーにしたハッシュ)から列の値を作る
  def self.attributes_from_parsed(row, index)
    { position: index, lecture_code: row['講義コード'], course_number: row['科目番号'], name: row['科目名'],
      credits: row['単位'], requirement_type: row['必修選択'], grade_text: row['受講年次'], weekday: row['曜日'],
      period_text: row['時限'], term_type: row['開講区分'], note: row['備考'], review_reason: row['要確認'].presence }
  end

  # 名前・番号が同じ既存の講義(同じ講義かどうかは人が選ぶ)
  def course_candidates
    return Course.none if course_number.blank? || name.blank?

    Course.where(course_number: course_number, name: name).order(:id)
  end

  def course_choice_resolved?
    register_as_new || course_id.present?
  end

  # 候補がちょうど1件で、単位も同じなら、その講義が既定の選択。
  # 候補が複数、または単位が違う(別の講義かもしれない)ときは、既定を決めず人に選んでもらう。
  def default_course
    candidates = course_candidates.limit(2).to_a
    candidates.first if candidates.one? && candidates.first.credits == credits_value
  end

  # まだ選ばれていない行に、既定の選択を付ける(人が選んだ内容は上書きしない)
  def assign_default_course_choice
    return if course_choice_resolved?

    self.course = default_course
  end

  def credits_value
    Integer(credits.to_s, 10, exception: false)
  end

  # セレクトボックスの現在値。'new' か既存講義のIDで、未選択は''。
  def course_choice
    return 'new' if register_as_new

    course_id.to_s
  end

  # セレクトボックスの値を、紐付け先に直す。候補に無いIDや空は未選択にする。
  def apply_course_choice(value)
    value = value.to_s
    self.register_as_new = value == 'new'
    self.course_id = value.match?(/\A\d+\z/) && course_candidates.exists?(id: value) ? value.to_i : nil
  end

  # 画面から送られた値を反映する(保存はしない)。
  # 名前・番号を直したときは候補が変わるので、それまでの選択を捨てて既定から選び直す。
  def apply_edit(values)
    EDITABLE.each { |field| self[field] = values[field].to_s.strip if values.key?(field) }
    if course_number_changed? || name_changed?
      self.course = nil
      self.register_as_new = false
    elsif values.key?(:course_choice)
      apply_course_choice(values[:course_choice])
    end
    assign_default_course_choice
  end

  def importer_values(review: '')
    { '要確認' => review, '既存講義ID' => course_id.to_s, '新規登録' => register_as_new ? '1' : '',
      '学期' => timetable_upload.semester, '講義コード' => lecture_code.to_s,
      '科目番号' => course_number.to_s, '科目名' => name.to_s, '単位' => credits.to_s,
      '必修選択' => requirement_type.to_s, '受講年次' => grade_text.to_s, '曜日' => weekday.to_s,
      '時限' => period_text.to_s, '開講区分' => term_type.to_s, '備考' => note.to_s }
  end

  # Importerに渡す行。確認済みでなければ「要確認」を残し、保存対象にしない。
  def importer_row
    importer_values(review: confirmed ? '' : (review_reason.presence || '未確認'))
  end

  def credits_mismatch_message
    "選んだ既存の講義の単位(#{course.credits})と違います。単位を直すか、別の講義として登録してください。"
  end

  # 今の値がDBに入れられる形か(確認済みにしてよいか)。問題があればその一覧を返す。
  def problems
    errors = TimetableImport::Importer::RowAttributes.new(importer_values).errors
    errors << TimetableImport::Importer::UNRESOLVED_MESSAGE if course_candidates.exists? && !course_choice_resolved?
    errors << credits_mismatch_message if course && course.credits != credits_value
    errors
  end
end

