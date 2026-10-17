# frozen_string_literal: true

# 架空の履修データは明示的なseed実行時のみ作成し、本番環境には投入しない。
DemoData.load! if DemoAccount.enabled?
