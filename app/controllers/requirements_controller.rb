# frozen_string_literal: true

# 卒業要件の確認。学生の便覧（@curriculum）に書かれた章・規則をそのまま見せる読み取り専用の画面。
# 描画に必要なものは StudentWorkspace が読み込んだ @curriculum だけなので、ここで足すものは無い。
class RequirementsController < ApplicationController
  include StudentWorkspace

  def show; end
end

