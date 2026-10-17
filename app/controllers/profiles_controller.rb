# frozen_string_literal: true

# マイページ。所属情報と公式資料へのリンクを表示する。
class ProfilesController < ApplicationController
  include StudentWorkspace

  def show
    load_history
    load_plans
  end
end

