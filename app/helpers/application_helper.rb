# frozen_string_literal: true

module ApplicationHelper
  APP_NAME = '卒業要件チェッカー'

  def app_name
    APP_NAME
  end

  # 画面の幅の上限。表の多い画面は content_for :wide を指定して広く使う
  def content_width_class
    content_for?(:wide) ? 'max-w-[110rem]' : 'max-w-7xl'
  end
end

