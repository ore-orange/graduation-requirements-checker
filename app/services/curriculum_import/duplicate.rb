# frozen_string_literal: true

module CurriculumImport
  # 公開済みの便覧を直すための、下書きの複製。公開済みの行は書き換えない(学生の判定が使っているため)。
  #
  # 複製した下書きは、直したあとに公開すると、同じ識別名・入学年度の公開済みを差し替える(Publication)。
  # 科目には確認済み(confirmed)を付ける。公開済みの科目は、公開の関門を通った(または実物のファイルとして人が書いた)もので、
  # 複製しただけで484科目を確認し直させると、一か所を直すためだけの作業が重すぎて、関門が使われなくなる。
  # ページの記録と画像は公開のときに捨てているので、複製に PDF は無く、読み直しもできない。直すのは、確認画面の人の手。
  module Duplicate
    def self.call(published)
      document = published.document.deep_dup
      CourseEdit.confirm_all!(document)
      Curriculum.create!(slug: published.slug, admission_year: published.admission_year, title: published.title,
                         faculty_name: published.faculty_name, department_name: published.department_name,
                         source_filename: '公開済みの複製', pages: [], document: document)
    end
  end
end

