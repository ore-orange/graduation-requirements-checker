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

    LECTURE_CODE = /\A\d{9}\z/
    REQUIREMENTS = { '必' => '必修', '選' => '選択' }.freeze
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
      pages.flat_map { |spans| page_rows(spans) }
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
        '単位' => cell(spans, :credits),
        '必修選択' => REQUIREMENTS.fetch(cell(spans, :requirement), cell(spans, :requirement)),
        '受講年次' => cell(spans, :grade),
        '曜日' => cell(spans, :weekday),
        '時限' => cell(spans, :periods),
        '開講区分' => cell(spans, :term_type),
        '備考' => note(spans)
      }
      row.merge('要確認' => review_reasons(row).join('、'))
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

