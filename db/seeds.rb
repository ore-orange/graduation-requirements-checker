# frozen_string_literal: true

# 架空の履修データは明示的なseed実行時のみ作成する。本番ではPUBLIC_DEMO=1のときだけ投入できる。
DemoData.load! if DemoAccount.enabled?
