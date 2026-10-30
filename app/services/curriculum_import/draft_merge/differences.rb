# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # 人が直して残した規則・章・行・区分と、読み直した結果の違いを、人が読む文にする。
    # 読み直しは人の直した値を採らない。そのとき AI の読みが違っていたことを、黙って捨てずに警告として残す
    # (直した値のほうが正しいとは限らない。違いが見えれば、もう一度見比べられる)。
    module Differences
      IGNORED = %w[id source_page confirmed].freeze
      LABELS = { 'required_credits' => '必要単位', 'label' => '名前', 'title' => '章の名前', 'name' => '名前',
                 'subtitle' => '副題', 'categories' => '区分', 'category' => '区分', 'check_id' => '確認する規則',
                 'check_ids' => '確認する規則', 'required_categories' => '必修の区分', 'expected_course_count' => '科目数',
                 'required_label' => '必要単位の表示', 'credits_from_check' => '規則から単位を取るか', 'detail' => '注記',
                 'row_ids' => '行', 'group_by' => 'グループの分け方', 'type' => '規則の型' }.freeze

      module_function

      def sentence(noun, id, differences)
        "#{noun}「#{id}」は人が直した内容を残しました。読み直した結果は違います: #{differences.join('、')}。"
      end

      # 違うところの文の配列。同じなら空。行(rows)は id で突き合わせる。
      def between(kept, incoming)
        (kept.keys | incoming.keys).excluding(*IGNORED).flat_map do |field|
          next rows_between(kept[field], incoming[field]) if field == 'rows'
          next [] if (kept[field].blank? && incoming[field].blank?) || kept[field] == incoming[field]

          ["#{LABELS.fetch(field, field)}(残した値: #{show(kept[field])} / 読み直した値: #{show(incoming[field])})"]
        end
      end

      def rows_between(kept_rows, incoming_rows)
        kept_rows = Array(kept_rows).grep(Hash).index_by { |row| row['id'] }
        incoming_rows = Array(incoming_rows).grep(Hash).index_by { |row| row['id'] }
        (kept_rows.keys | incoming_rows.keys).flat_map do |id|
          next ["行「#{id}」は読み直した結果に無い"] unless incoming_rows.key?(id)
          next ["行「#{id}」は読み直した結果にだけある"] unless kept_rows.key?(id)

          between(kept_rows[id], incoming_rows[id]).map { |text| "行「#{id}」の#{text}" }
        end
      end

      def show(value)
        return '無し' if value.nil?
        return value.to_s unless value.is_a?(Array) || value.is_a?(Hash)
        return '内容が違う' unless scalars?(value)

        value.join('・').presence || '空'
      end

      def scalars?(value)
        value.is_a?(Array) && value.all? { |item| item.is_a?(String) || item.is_a?(Numeric) }
      end

      # 人が直した区分と、読み直した内容の違い。直した側を残したことを、違いごとに知らせる。
      def kept_category(noun, existing, entry)
        differences = []
        if existing['label'] != entry['label']
          differences << "#{noun} #{entry['key']} の名前は、人が直した「#{existing['label']}」を残しました" \
                         "(読み直した結果: #{entry['label']})。"
        end
        if existing['counts_toward_total'] != entry['counts_toward_total']
          differences << "#{noun} #{entry['key']} の「卒業の総単位に数えるか」は、" \
                         "人が直した値(#{existing['counts_toward_total']})を残しました(読み直した結果: #{entry['counts_toward_total']})。"
        end
        differences
      end
    end
  end
end

