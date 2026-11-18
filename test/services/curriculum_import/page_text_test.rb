# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  class PageTextTest < ActiveSupport::TestCase
    def tidy(raw) = PageText.tidy(raw.b)

    test '列の間の余白は、幅によらず1つのタブにする' do
      assert_equal "工共100\t工学基礎演習\t2\t2-0\t1\t前", tidy("   工共100 工学基礎演習      2   2-0  1      前   \n")
    end

    test '隣り合う列の間の空白1つも、列の境として残す(続けると別の列が1つの語に見える)' do
      assert_equal "単位数\t必修\t分類", tidy("単位数 必修  分類\n")
    end

    test '英単語の間の空白1つだけは、そのまま残す' do
      assert_equal "工共320\tFrontiers of Engineering\t2", tidy("工共320 Frontiers of Engineering          2\n")
      assert_equal "Frontiers\tof", tidy("Frontiers  of\n"), '2つ以上は列の境'
    end

    test '行頭・行末の空白と空行は落とす' do
      assert_equal "一\n二", tidy("\n    \n  一  \n\n     二\n")
    end

    test '制御文字とNULを除き、不正なバイトは落とす' do
      assert_equal "一\n二", tidy("一\u0000\r\n\f二\xFF\n")
    end

    test '全角空白は本文の一部として残す' do
      assert_equal '　は，GE指定科目', tidy("　は，GE指定科目\n")
    end
  end
end

