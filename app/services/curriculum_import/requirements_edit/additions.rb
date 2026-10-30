# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 章と行を、人が足す。AI が表の1章・1行を読み落とすと、その区分がどの行にも出ず、公開できない下書きが残る
    # (Validation が止める)。直す手段が無いと、その下書きは捨てるしかない。
    # 足した章・行には、読み直しで消えないよう confirmed を付ける。入力が空の欄は、足さない(画面は空の組を毎回送る)。
    module Additions
      NEW_GROUP_FIELDS = { 'title' => :text, 'required_credits' => :number, 'check_id' => :optional_text }.freeze
      NEW_ROW_FIELDS = { 'name' => :text, 'subtitle' => :text, 'required_credits' => :number, 'required_label' => :text,
                         'categories' => :set, 'check_ids' => :list, 'credits_from_check' => :flag }.freeze
      GROUP_START = %i[id title required_credits check_id].freeze
      ROW_START = %i[id name subtitle required_credits required_label].freeze

      private

      def add_new_group
        entry = @params[:new_group]
        return unless filled?(entry, GROUP_START)

        display = display_for_addition or return
        groups = list_of(display, 'groups') or return

        in_context('new_group', 'new') do
          group = build(entry, NEW_GROUP_FIELDS, '章')
          problem = group_problem(group, groups, entry)
          return error(problem) if problem
          return if @problems.any? { |item| item.kind == 'new_group' }

          groups << group.merge('id' => new_id(entry[:id], groups.pluck('id'), 'group'), 'rows' => [],
                                DraftMerge::CONFIRMED => true)
          added("章「#{group['title']}」を足しました。")
        end
      end

      def add_new_row
        entry = @params[:new_row]
        return unless filled?(entry, ROW_START)

        groups = Array(@document.dig('display', 'groups')).grep(Hash)
        in_context('new_row', 'new') do
          group = groups.find { |item| item['id'] == entry[:group_id] }
          next error('行を足す章を選んでください。') unless group

          row = build(entry, NEW_ROW_FIELDS, '行')
          problem = row_problem(row, groups, entry)
          next error(problem) if problem

          append_row(group, groups, row, entry) if @problems.none? { |item| item.kind == 'new_row' }
        end
      end

      def append_row(group, groups, row, entry)
        taken = groups.flat_map { |item| Array(item['rows']).grep(Hash).pluck('id') }
        (group['rows'] ||= []) << row.merge('id' => new_id(entry[:id], taken, 'row'), DraftMerge::CONFIRMED => true)
        added("行「#{row['name']}」を、章「#{group['title']}」に足しました。")
      end

      def filled?(entry, fields)
        entry.is_a?(Hash) && fields.any? { |field| entry[field].to_s.strip.present? }
      end

      # 欄を型に直す。直せない欄は、その問題を積む(型が合わない値は :invalid のまま捨てる)。
      def build(entry, fields, noun)
        fields.each_with_object({}) do |(field, type), item|
          value = coerce(entry[field], type, "足す#{noun}の#{FIELD_LABELS.fetch(field, field)}")
          item[field] = value unless value == :invalid || (value.nil? && type == :optional_text)
        end
      end

      def group_problem(group, groups, entry)
        return '足す章の名前を入れてください。' if group['title'].blank?
        return '足す章の必要単位を数で入れてください。' unless group['required_credits'].is_a?(Numeric)

        "章の id「#{entry[:id]}」はすでにあります。" if groups.pluck('id').include?(entry[:id].to_s.strip)
      end

      # 必要単位が空の行は、理由を表す表示の文が要る(Catalogue が求める)。
      def row_problem(row, groups, entry)
        return '足す行の名前を入れてください。' if row['name'].blank?
        if !row['required_credits'].is_a?(Numeric) && row['required_label'].blank?
          return '足す行は、必要単位を数で入れるか、必要単位が空のときの表示(内数22単位枠など)を入れてください。'
        end

        taken = groups.flat_map { |group| Array(group['rows']).grep(Hash).pluck('id') }
        "行の id「#{entry[:id]}」はすでにあります。" if taken.include?(entry[:id].to_s.strip)
      end

      def display_for_addition
        @document['display'] = {} if @document['display'].nil?
        @document['display'].is_a?(Hash) ? @document['display'] : error('display はハッシュでなければなりません。')
      end

      def added(note)
        @edited += 1
        @notes << note
      end
    end
  end
end

