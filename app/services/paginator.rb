# frozen_string_literal: true

# 件数と現在のページ番号から、表示範囲とページ数を求める(gemを増やさないための最小実装)。
class Paginator
  PER_PAGE = 30
  WINDOW = 5

  attr_reader :total, :per, :page

  def initialize(total:, page:, per: PER_PAGE)
    @total = total
    @per = per
    # 範囲外・不正なページ番号は、最初か最後のページに丸める
    @page = page.to_i.clamp(1, pages)
  end

  def pages
    [(total.to_f / per).ceil, 1].max
  end

  def offset
    (page - 1) * per
  end

  def first_item
    total.zero? ? 0 : offset + 1
  end

  def last_item
    [offset + per, total].min
  end

  def paginated?
    pages > 1
  end

  # 表示するページ番号。現在のページを中心に最大WINDOW個(端では寄せて個数を保つ)
  def window
    first = (page - (WINDOW / 2)).clamp(1, [pages - WINDOW + 1, 1].max)
    (first..[first + WINDOW - 1, pages].min).to_a
  end

  def previous_page
    page - 1 if page > 1
  end

  def next_page
    page + 1 if page < pages
  end
end

