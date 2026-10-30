# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 修正の記録を付ける道具。問題の集め方・直した印・消したものの記録・送られた値を項目に当てる処理。
    module Bookkeeping
      TRUE_VALUES = [true, '1', 'true', 'on'].freeze

      private

      # 問題を積む。kind と id を渡さなければ、いま当てている項目(assign が決める)の問題になる。
      def error(message, kind = @context&.first, id = @context&.last)
        @problems << Problem.new(message, kind, id)
        @touched << [kind, id] if kind
        nil
      end

      def list_of(owner, field)
        value = owner[field]
        return owner[field] = [] if value.nil?
        return value if value.is_a?(Array) && value.all?(Hash)

        error("#{field} が配列でないか、ハッシュでない要素があるため、この画面では直せません。")
      end

      # 送られた項目の配列。配列でも、{ '0' => {...}, '1' => {...} } でも受ける。無ければ nil。
      def entries(value, name)
        return if value.nil?
        return value if value.is_a?(Array) && value.all?(Hash)
        return value.values if value.is_a?(Hash) && value.values.all?(Hash)

        error("#{name} の形が違います。")
      end

      # 送られた値を項目に当てる。値が変わった欄の名前を返す(変わらなければ空)。
      # 画面は全部の欄を送ってくる。書式の違い(前後の空白・改行の形・無い欄と空の欄)だけの差は、直したことにしない。
      # 直したことにすると、触っていない項目まで確認済みの印が付き、読み直しで AI の読みを受け取れなくなる。
      def assign(item, entry, fields, kind, id)
        changed = in_context(kind, id) do
          fields.filter_map do |field, type|
            next unless entry.key?(field)

            value = coerce(entry[field], type, "#{KIND_NAMES.fetch(kind)}「#{id}」の#{FIELD_LABELS.fetch(field, field)}")
            next if value == :invalid || same?(type, field, value, item[field])

            store(item, field, type, value)
            field
          end
        end
        @touched << [kind, id] if changed.any?
        changed
      end

      # ブロックの中で積む問題を、この項目のものにする。
      def in_context(kind, id)
        @context = [kind, id]
        yield
      ensure
        @context = nil
      end

      def store(item, field, kind, value)
        if value.nil? && kind == :optional_text
          item.delete(field)
        else
          item[field] = value
        end
      end

      # 直した項目に印を付ける(直していなければ何もしない)。直した数は項目ごとに1つ数える。
      def mark(item, changed)
        return unless changed

        @edited += 1 unless @counted.include?(item.object_id)
        @counted << item.object_id
        item[DraftMerge::CONFIRMED] = true
      end

      def destroy?(entry)
        TRUE_VALUES.include?(entry[:_destroy])
      end

      # 消したものを記録する。読み直しが、同じ id(と、付け替わった id の元の由来)を戻さないように。
      # removed には消した id を積む。戻り値は nil。
      def discard(item, kind, removed = [], group_id = nil)
        removed << item['id']
        page = owner_page(kind, item['id'], group_id)
        origin = page&.dig('contributed', 'origins', ORIGIN_FIELD.fetch(kind), item['id'])
        (@document[DraftMerge::REMOVED] ||= []) << { 'kind' => kind, 'id' => item['id'], 'page' => page&.dig('page'),
                                                     'origin' => origin }.compact
        @edited += 1
        @touched << [kind, item['id']]
        @notes << "#{KIND_NAMES.fetch(kind)}「#{item['id']}」を消しました。読み直しても戻りません。"
        nil
      end

      # 消したものを足したページ。読み直す前の警告で、どのページの読み直しで戻らないかを言うために持つ。
      def owner_page(kind, id, group_id)
        field = CONTRIBUTED_FIELD.fetch(kind, 'groups')
        target = group_id || id
        @pages.find { |page| Array(page.dig('contributed', field)).include?(target) }
      end

      # 人が足す項目の id。空なら、重ならない id を作る。足し直す id が消したものの記録にあれば、その記録は外す(人が戻した)。
      def new_id(given, taken, kind)
        id = given.to_s.strip
        id = "added_#{kind}_#{(1..).find { |n| taken.exclude?("added_#{kind}_#{n}") }}" if id.empty?
        clear_removed(kind, id)
        id
      end

      # 人が足し直した id は、消したものの記録から外す(人が戻した。読み直しは、また入れてよい)。
      def clear_removed(kind, id)
        (@document[DraftMerge::REMOVED] || []).reject! { |entry| entry['kind'] == kind && entry['id'] == id }
      end
    end
  end
end

