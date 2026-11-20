# frozen_string_literal: true

# 卒業要件の確認。学部・学科コース・入学年度を選んでから、その便覧に書かれた章・規則を見せる読み取り専用の画面。
# 学生の便覧ではなく、選んだ組み合わせから便覧を引く。だから学生(StudentWorkspace)は読み込まない。
# 守りは ApplicationController の Authentication（ログイン必須）に委ねる。
#
# 選択肢は CurriculumChoices、選んだ値の解釈と便覧の引き当ては CurriculumSelection が持つ。
class RequirementsController < ApplicationController
  # 選択の結果は3通りで、どれも @selection（選んだ値）を持つ。
  #   公開済みがある … @published（レコード）と、判定に使う @curriculum（文書）・@catalogue。下書きがあれば @drafts も。
  #   下書きだけがある … @drafts
  #   どちらも無い … 何も持たない（画面が「まだありません」と PDF の入口を出す）
  def show
    @choices = CurriculumChoices.new
    @selection = CurriculumSelection.new(params, choices: @choices)
    @drafts = @selection.drafts
    @published = @selection.published
    return unless @published

    @curriculum = @published.document
    # この画面は、アプリが判定に使う要件を見せる。Catalogue を作って読み込み時の検査を通し、判定側が弾く便覧は
    # 他の画面と同じく例外にする。弾かれる便覧のまま描くと、読めない要件を読めるかのように見せてしまう。
    # 便覧が決まったときだけ作る（選んでいない・便覧が無いときに、何も無い文書で呼ばない）。
    @catalogue = GraduationAssessment::Catalogue.new(@curriculum)
    # 科目表は、便覧の文書ではなく科目の名簿から描く。
    @directory = CourseDirectory.new(@curriculum)
  end
end

