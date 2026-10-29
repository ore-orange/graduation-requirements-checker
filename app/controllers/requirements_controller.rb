# frozen_string_literal: true

# 卒業要件の確認。学生の便覧（@curriculum）に書かれた章・規則をそのまま見せる読み取り専用の画面。
class RequirementsController < ApplicationController
  include StudentWorkspace

  # この画面は、アプリが判定に使う要件を見せる。Catalogue を作って読み込み時の検査を通し、判定側が弾く便覧は
  # 他の画面と同じく例外にする。弾かれる便覧のまま描くと、読めない要件を読めるかのように見せてしまう。
  def show
    @catalogue = GraduationAssessment::Catalogue.new(@curriculum)
  end
end

