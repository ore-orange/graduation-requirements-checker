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

    test 'returns no rows for a page without lecture codes' do
      assert_empty parse(header)
    end
  end
end

