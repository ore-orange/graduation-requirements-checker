# frozen_string_literal: true

require 'test_helper'

class PaginatorTest < ActiveSupport::TestCase
  test 'splits into pages of 30 by default' do
    paginator = Paginator.new(total: 65, page: 2)

    assert_equal 3, paginator.pages
    assert_equal [30, 31, 60], [paginator.offset, paginator.first_item, paginator.last_item]
    assert_equal [1, 3], [paginator.previous_page, paginator.next_page]
  end

  test 'last page holds the remainder' do
    paginator = Paginator.new(total: 65, page: 3)

    assert_equal [61, 65, nil], [paginator.first_item, paginator.last_item, paginator.next_page]
  end

  test 'exactly one page is not paginated' do
    paginator = Paginator.new(total: 30, page: 1)

    assert_equal 1, paginator.pages
    assert_not paginator.paginated?
  end

  test 'empty list still has one empty page' do
    paginator = Paginator.new(total: 0, page: 1)

    assert_equal [1, 0, 0], [paginator.pages, paginator.first_item, paginator.last_item]
  end

  test 'invalid or out of range pages are clamped' do
    assert_equal 1, Paginator.new(total: 65, page: nil).page
    assert_equal 1, Paginator.new(total: 65, page: 'abc').page
    assert_equal 1, Paginator.new(total: 65, page: '-3').page
    assert_equal 3, Paginator.new(total: 65, page: '99').page
  end

  test 'window shows up to 5 page numbers centred on the current page' do
    assert_equal [1, 2, 3, 4, 5], Paginator.new(total: 300, page: 1).window
    assert_equal [1, 2, 3, 4, 5], Paginator.new(total: 300, page: 3).window
    assert_equal [3, 4, 5, 6, 7], Paginator.new(total: 300, page: 5).window
    assert_equal [6, 7, 8, 9, 10], Paginator.new(total: 300, page: 10).window
    assert_equal [1, 2, 3], Paginator.new(total: 65, page: 2).window
  end
end

