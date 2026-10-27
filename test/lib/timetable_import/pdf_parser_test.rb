# frozen_string_literal: true

require 'test_helper'

module TimetableImport
  class PdfParserTest < ActiveSupport::TestCase
    # gs -sDEVICE=txtwrite -dTextFormat=0 の出力と同じ形のXMLを作る
    def span(text, left, top)
      chars = text.chars.map { |char| %(<char bbox="#{left} #{top} #{left + 1} #{top}" c="#{CGI.escapeHTML(char)}"/>) }
      %(<span bbox="#{left} #{top} #{left + (text.size * 5)} #{top}" font="F" size="10">#{chars.join}</span>)
    end

    def header
      [span('(許可コード)', 723, 124), span('科目名', 178, 119)]
    end

    def course(code:, top:, number: '工共100', name: '工学基礎演習', credits: '2', requirement: '必',
               grade: '1', weekday: '金', periods: '2・3', term: '1Q', extra: [])
      [span(code, 64, top), span(number, 107, top), span(name, 167, top), span(credits, 250, top),
       span(requirement, 310, top), span(grade, 477, top), span(weekday, 505, top), span(periods, 523, top),
       span(term, 686, top), span('※備考', 775, top), *extra]
    end

    def parse(*pages, semester: '前期')
      xml = pages.map { |spans| "<page>\n#{spans.join("\n")}\n</page>\n" }.join
      PdfParser.new(xml, semester: semester).rows
    end

    test 'reads one course row by column position' do
      row = parse(header + course(code: '610000071', top: 153)).first

      assert_equal(
        { '学期' => '前期', '講義コード' => '610000071', '科目番号' => '工共100', '科目名' => '工学基礎演習',
          '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金', '時限' => '2・3',
          '開講区分' => '1Q', '備考' => '※備考', '要確認' => '' },
        row
      )
    end

    test 'semester comes from the argument, not the pdf' do
      assert_equal '後期', parse(header + course(code: '610000071', top: 153), semester: '後期').first['学期']
    end

    test 'joins a course name wrapped onto the line below' do
      wrapped = course(code: '617028001', top: 206, name: 'ヒューマンコンピュータインタ') + [span('ラクション', 175, 211)]
      assert_equal 'ヒューマンコンピュータインタラクション', parse(header + wrapped).first['科目名']
    end

    test 'assigns a name placed above the code line to the nearest course' do
      first = course(code: '610000071', top: 153)
      second = course(code: '610002071', top: 189, name: '') + [span('工業数学Ⅰ', 171, 186)]
      names = parse(header + first + second).pluck('科目名')
      assert_equal %w[工学基礎演習 工業数学Ⅰ], names
    end

    test 'ignores header text above the first course' do
      assert_equal 1, parse(header + course(code: '610000071', top: 153)).size
    end

    test 'reads every page' do
      pages = [header + course(code: '610000071', top: 153), header + course(code: '610002071', top: 153)]
      assert_equal(%w[610000071 610002071], parse(*pages).pluck('講義コード'))
    end

    test 'flags unclear schedule but allows intensive courses without one' do
      unclear = course(code: '610013071', top: 153, periods: '4(・5)')
      intensive = course(code: '610012071', top: 189, weekday: '', periods: '', term: '集中')
      rows = parse(header + unclear + intensive)

      assert_equal '時限が不明', rows[0]['要確認']
      assert_equal '', rows[1]['要確認']
    end

    test 'flags rows whose credits or requirement cannot be read' do
      row = parse(header + course(code: '610000071', top: 153, credits: '', requirement: '')).first
      assert_equal '単位が整数でない、必修選択が不明', row['要確認']
    end

    # 縮尺の違うPDF(知能情報コースの後半など)は、全体のx座標が縮んでいる。見出しの位置から基準の座標に直して読む。
    def scaled_header
      [span('科目番', 91, 102), span('科目名', 151, 106), span('単', 211, 102), span('必修', 260, 102),
       span('受', 400, 102), span('曜', 430, 102), span('期間', 565, 106), span('(許可コード)', 602, 110)]
    end

    def scaled_course(code:, top:)
      [span(code, 54, top), span('工共114', 90, top), span('プログラミングI', 140, top), span('2', 213, top),
       span('必', 264, top), span('1', 407, top), span('金', 430, top), span('1', 448, top),
       span('半年', 565, top), span('※備考', 644, top)]
    end

    test 'reads a pdf whose table is narrower than the reference layout' do
      row = parse(scaled_header + scaled_course(code: '610004072', top: 137)).first

      assert_equal(
        { '学期' => '前期', '講義コード' => '610004072', '科目番号' => '工共114', '科目名' => 'プログラミングI',
          '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金', '時限' => '1',
          '開講区分' => '半年', '備考' => '※備考', '要確認' => '' },
        row
      )
    end

    test 'a page without its own header reuses the previous page header' do
      continuation = scaled_course(code: '610048072', top: 137)
      assert_equal %w[工共114 工共114], parse(scaled_header + scaled_course(code: '610004072', top: 137), continuation)
        .pluck('科目番号')
    end

    test 'normalizes quarter wording and half-width digits' do
      rows = parse(header + course(code: '610000071', top: 153, term: '１クォーター') +
                   course(code: '610002071', top: 189, term: '3Q', grade: '3･4'))

      assert_equal %w[1Q 3Q], rows.pluck('開講区分')
      assert_equal %w[1 3・4], rows.pluck('受講年次')
      assert_equal ['', ''], rows.pluck('要確認')
    end

    test 'accepts a full-year course' do
      assert_equal '', parse(header + course(code: '610000071', top: 153, term: '通年')).first['要確認']
    end

    test 'flags a term that is not a known one' do
      row = parse(header + course(code: '610000071', top: 153, term: '前期')).first
      assert_equal '開講区分が不明', row['要確認']
    end

    test 'returns no rows for a page without lecture codes' do
      assert_empty parse(header)
    end
  end
end

