# frozen_string_literal: true

require 'cgi'
require 'open3'
require_relative 'values'

module TimetableImport
  # 授業時間配当表PDFを、Ghostscriptが出力する座標付きテキスト(XML)から表の行に直す。
  # PDFの1科目は複数行にまたがるため、講義コード(9桁)の行を基準に、
  # 各テキストを最も近い基準行へ振り分ける。列は左端のx座標で判定する。
  class PdfParser
    class Error < StandardError; end

    Span = Struct.new(:x, :y, :text)

    # 左端のx座標の範囲(PDFの表の列位置)
    COLUMNS = {
      lecture_code: 60..104,
      course_number: 105..137,
      name: 138..244,
      credits: 245..266,
      requirement: 300..326,
      grade: 460..502,
      weekday: 503..520,
      periods: 521..545,
      term_type: 675..705,
      note: 770..2000
    }.freeze

    # 見出し文字と、それが上の列位置(COLUMNS)の座標系で出てくるx座標。
    # PDFによって表の幅(縮尺)が違うので、見出しがこの位置に重なるようにx座標を伸縮してから列を判定する。
    HEADER_ANCHORS = {
      /\A科目番/ => 108, /\A科目名\z/ => 178, /\A単/ => 247, /\A必修/ => 305,
      /\A受/ => 469, /\A曜/ => 505, /\A期間\z/ => 682
    }.freeze

    LECTURE_CODE = /\A\d{9}\z/
    REQUIREMENTS = { '必' => '必修', '選' => '選択' }.freeze
    TERM_TYPES = %w[半年 1Q 2Q 3Q 4Q 通年 集中].freeze
    # 「第1Q」「１クォーター」など、n番目のクォーターの書き方
    QUARTER = /\A第?(\d)(?:Q|クォーター)\z/
    # 表の最初の行の上にある見出し行を除くための余裕
    HEADER_MARGIN = 20
    LINE_GAP = 6

    def self.extract_xml(pdf_path)
      xml, status = Open3.capture2('gs', '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=txtwrite', '-dTextFormat=0',
                                   '-sOutputFile=-', pdf_path)
      raise Error, 'Ghostscript(gs)でPDFを読み取れませんでした。gsが入っているか確認してください。' unless status.success?

      xml.force_encoding(Encoding::UTF_8)
    rescue Errno::ENOENT
      raise Error, 'Ghostscript(gs)が見つかりません。brew install ghostscript などで導入してください。'
    end

    def initialize(xml, semester:)
      @xml = xml
      @semester = semester
    end

    def rows
      points = []
      pages.flat_map do |spans|
        found = header_points(spans)
        points = found unless found.empty?
        page_rows(align_to_reference(spans, points))
      end
    end

    private

    def pages
      @xml.split('<page>').drop(1).map { |page| page_spans(page) }
    end

    def page_spans(page)
      page.scan(%r{<span bbox="(\d+) (\d+) \d+ \d+"[^>]*>(.*?)</span>}m).map do |x, y, body|
        text = body.scan(/\bc="([^"]*)"/).flatten.map { |char| CGI.unescapeHTML(char) }.join
        Span.new(x.to_i, y.to_i, text)
      end
    end

    # 見出しが無いページ(前のページの続き)は、前のページの見出しの位置を使う。
    # どのページにも見出しが無ければ、そのままの座標で判定する。
    def align_to_reference(spans, points)
      return spans if points.size < 2

      spans.map { |span| Span.new(reference_x(points, span.x), span.y, span.text) }
    end

    # [このPDFでの見出しのx座標, 基準のx座標] を、x座標の小さい順に返す。順序が基準と食い違うときは使わない。
    def header_points(spans)
      first_code_y = spans.select { |span| span.text.match?(LECTURE_CODE) }.map(&:y).min
      return [] unless first_code_y

      header = spans.select { |span| span.y < first_code_y }
      points = HEADER_ANCHORS.filter_map { |pattern, reference| header_point(header, pattern, reference) }.sort
      same_order?(points) ? points : []
    end

    def same_order?(points)
      points.each_cons(2).all? { |left, right| left[0] < right[0] && left[1] < right[1] }
    end

    def header_point(header, pattern, reference)
      found = header.select { |span| span.text.match?(pattern) }.max_by(&:y)
      [found.x, reference] if found
    end

    # 見出しの位置の間は線形に、両端の外側は端の区間の伸縮率で延ばして、基準のx座標に直す。
    def reference_x(points, left_edge)
      from, to = points.each_cons(2).find { |_, upper| left_edge <= upper[0] } || points.last(2)
      (from[1] + ((left_edge - from[0]) * (to[1] - from[1]).fdiv(to[0] - from[0]))).round
    end

    def page_rows(spans)
      anchors = spans.select { |span| COLUMNS[:lecture_code].cover?(span.x) && span.text.match?(LECTURE_CODE) }
      return [] if anchors.empty?

      groups = group_by_nearest_anchor(spans, anchors)
      anchors.sort_by(&:y).map { |anchor| build_row(anchor, groups.fetch(anchor, [])) }
    end

    def group_by_nearest_anchor(spans, anchors)
      limit = header_bottom(spans, anchors)
      body = (spans - anchors).reject { |span| span.y <= limit }
      body.group_by { |span| anchors.min_by { |anchor| (anchor.y - span.y).abs } }
    end

    # 見出し行の最終行(「(許可コード)」)より上は表の本体ではない
    def header_bottom(spans, anchors)
      header = spans.find { |span| span.text.include?('許可コ') }
      header ? header.y + 2 : anchors.map(&:y).min - HEADER_MARGIN
    end

    def build_row(anchor, spans)
      row = {
        '学期' => @semester,
        '講義コード' => anchor.text,
        '科目番号' => cell(spans, :course_number),
        '科目名' => name(spans),
        '単位' => half_width(cell(spans, :credits)),
        '必修選択' => REQUIREMENTS.fetch(cell(spans, :requirement), cell(spans, :requirement)),
        '受講年次' => half_width(cell(spans, :grade)),
        '曜日' => cell(spans, :weekday),
        '時限' => half_width(cell(spans, :periods)),
        '開講区分' => term_type(cell(spans, :term_type)),
        '備考' => note(spans)
      }
      row.merge('要確認' => review_reasons(row).join('、'))
    end

    def half_width(text)
      text.tr('０-９･', '0-9・')
    end

    def term_type(text)
      quarter = half_width(text).match(QUARTER)
      quarter ? "#{quarter[1]}Q" : text
    end

    def column_spans(spans, column)
      spans.select { |span| COLUMNS.fetch(column).cover?(span.x) }
    end

    def cell(spans, column)
      column_spans(spans, column).sort_by { |span| [span.y, span.x] }.map(&:text).join.delete(' 　')
    end

    # 長い科目名は複数行に折り返されるため、行ごとにx順で連結してから上の行から繋ぐ
    def name(spans)
      lines(column_spans(spans, :name)).map { |line| line.sort_by(&:x).map(&:text).join }.join.strip
    end

    def note(spans)
      lines(column_spans(spans, :note)).map { |line| line.sort_by(&:x).map(&:text).join.strip }.join(' ')
    end

    def lines(spans)
      spans.sort_by(&:y).slice_when { |a, b| b.y - a.y > LINE_GAP }.to_a
    end

    # 自動で確信を持てない行に理由を付ける。人が直して空にするまでDBには保存されない。
    def review_reasons(row)
      reasons = []
      reasons << '科目番号なし' if row['科目番号'].empty?
      reasons << '科目名なし' if row['科目名'].empty?
      reasons << '単位が整数でない' unless row['単位'].match?(/\A\d+\z/)
      reasons << '必修選択が不明' unless Values::REQUIREMENT_TYPES.include?(row['必修選択'])
      reasons << '受講年次が不明' unless row['受講年次'].match?(Values::DIGIT_LIST)
      reasons << '開講区分が不明' unless TERM_TYPES.include?(row['開講区分'])
      reasons.concat(schedule_reasons(row))
    end

    def schedule_reasons(row)
      return [] if row['開講区分'] == '集中'

      reasons = []
      reasons << '曜日が不明' unless Values::WEEKDAYS.include?(row['曜日'])
      reasons << '時限が不明' unless row['時限'].match?(Values::DIGIT_LIST)
      reasons
    end
  end
end

