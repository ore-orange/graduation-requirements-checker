# frozen_string_literal: true

# 認証がないため、マスタを書き換える画面はローカルの開発・テスト環境に限る(デモ画面と同じ条件)。
module LocalAccessOnly
  extend ActiveSupport::Concern

  included do
    before_action :require_local_access
  end

  private

  def require_local_access
    head :not_found unless local_demo_access?
  end
end

