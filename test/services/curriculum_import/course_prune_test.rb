# frozen_string_literal: true

require 'test_helper'

module CurriculumImport
  class CoursePruneTest < ActiveSupport::TestCase
    def course(number, **fields)
      { 'key' => "c_#{number}", 'number' => number, 'name' => number, 'category' => 'intel', 'selectable' => true }
        .merge(fields.stringify_keys)
    end

    def document
      { 'categories' => [{ 'key' => 'intel', 'label' => '知能', 'number_patterns' => ['知能4'] },
                         { 'key' => 'other', 'label' => '他', 'number_patterns' => ['他'] }],
        'courses' => [course('知能401'), course('知能402', confirmed: true), course('知能403', added_by_hand: true),
                      course('知能404', required: true), course('知能501'), course('他101', category: 'other')] }
    end

    test '確認済み・手で足した科目を残す(drop_confirmed: false)' do
      doc = document

      dropped = CoursePrune.call(doc, drop_confirmed: false)

      assert_equal %w[知能401 他101], dropped.pluck('number')
      assert_equal %w[知能402 知能403 知能404 知能501], doc['courses'].pluck('number')
    end

    test '確認済み・手で足した科目も外す(drop_confirmed: true)。必修などは残す' do
      doc = document

      dropped = CoursePrune.call(doc, drop_confirmed: true)

      assert_equal %w[知能401 知能402 知能403 他101], dropped.pluck('number')
      assert_equal %w[知能404 知能501], doc['courses'].pluck('number')
    end

    test 'only を渡すと、その区分のパターンだけで判定する' do
      doc = document

      dropped = CoursePrune.call(doc, drop_confirmed: true, only: ['intel'])

      assert_equal %w[知能401 知能402 知能403], dropped.pluck('number')
      assert_includes doc['courses'].pluck('number'), '他101'
    end

    test 'dropping は文書を変えない' do
      doc = document

      assert_equal 4, CoursePrune.dropping(doc, drop_confirmed: true).size
      assert_equal 6, doc['courses'].size
    end

    test '壊れた文書でも例外にしない' do
      assert_equal [], CoursePrune.call({}, drop_confirmed: true)
      assert_equal [], CoursePrune.call({ 'courses' => 'x' }, drop_confirmed: true)
    end
  end
end

