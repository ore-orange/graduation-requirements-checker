# frozen_string_literal: true

require 'test_helper'

class CourseNumberTest < ActiveSupport::TestCase
  test 'prefix は数字の手前までを返す' do
    assert_equal '知能', CourseNumber.prefix('知能103')
    assert_equal '工共', CourseNumber.prefix('工共100')
    assert_equal 'C', CourseNumber.prefix('C101')
  end

  test 'hundreds は接頭辞と百の位を返す' do
    assert_equal '外2', CourseNumber.hundreds('外203')
    assert_equal '知能9', CourseNumber.hundreds('知能993')
  end

  test '全角数字も半角として読む' do
    assert_equal '知能', CourseNumber.prefix('知能１０３')
    assert_equal '知能1', CourseNumber.hundreds('知能１０３')
  end

  test '読めない値は nil' do
    [nil, '', '   ', '知能', '103'].each do |value|
      assert_nil CourseNumber.prefix(value), value.inspect
      assert_nil CourseNumber.hundreds(value), value.inspect
    end
  end
end

