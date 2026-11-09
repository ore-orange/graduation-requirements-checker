# frozen_string_literal: true

module CurriculumImport
  class RequirementsEdit
    # 画面から送られた文字を、文書に入る型(文字・数・整数・はい/いいえ・一覧・集合)にする。
    # 一覧(:list)は並びに意味がある id の列。集合(:set)は並びに意味が無いもの(区分のチェック。画面は区分の並びで送るので、
    # 元の並びと違っても、同じ区分なら変えたことにしない)。読めなければエラーを積んで :invalid を返す。
    # 何も入っていない欄は nil(一覧は空配列)。数を入れるべき欄に文字が入っていても、黙って 0 や nil にはしない。
    module Coercion
      TRUE_VALUES = [true, '1', 'true', 'on'].freeze
      FALSE_VALUES = [false, nil, '', '0', 'false', 'off'].freeze
      NUMBER = /\A-?\d+(\.\d+)?\z/
      # 欄が無いときの値(画面の初期の表示と、判定の読み方に合わせる)。
      FLAG_DEFAULTS = { 'counts_toward_total' => true, 'credits_from_check' => false }.freeze

      private

      def coerce(value, kind, name)
        case kind
        when :text, :optional_text then text(value, name)
        when :number then number(value, name)
        when :count then count(value, name)
        when :flag then flag(value, name)
        when :list, :set then list(value, name)
        else nested_coerce(value, kind, name)
        end
      end

      def text(value, name)
        return nil if value.nil?
        return normalize(value) if value.is_a?(String)

        error("#{name}は文字で入れてください。")
        :invalid
      end

      def normalize(string) = string.gsub("\r\n", "\n").strip.presence

      def number(value, name)
        return value if value.is_a?(Numeric) && value.to_f.finite?
        return nil if value.nil? || value.to_s.strip.empty?

        string = value.to_s.strip.tr('０-９．－', '0-9.-')
        return invalid("#{name}は数で入れてください(入れた値: #{value.to_s.first(20)})。") unless string.match?(NUMBER)

        decimal = BigDecimal(string)
        decimal.frac.zero? ? decimal.to_i : decimal.to_f
      end

      def count(value, name)
        result = number(value, name)
        return result unless result.is_a?(Float)

        invalid("#{name}は整数で入れてください(入れた値: #{value.to_s.first(20)})。")
      end

      def flag(value, name)
        return true if TRUE_VALUES.include?(value)
        return false if FALSE_VALUES.include?(value)

        invalid("#{name}は「はい・いいえ」で入れてください。")
      end

      # 区分や規則の id の並び。配列でも、カンマ・空白・読点で区切った文字でも受ける。
      def list(value, name)
        items = case value
                when Array then value
                when String then value.split(/[,、\s]+/)
                when nil then []
                else return invalid("#{name}は一覧で入れてください。")
                end
        items.filter_map { |item| item.to_s.strip.presence }
      end

      def invalid(message)
        error(message)
        :invalid
      end

      # 書式の違い(前後の空白・改行の形・無い欄と空の欄)だけの差かどうか。
      def same?(kind, field, value, current)
        return value.sort == Array(current).sort if kind == :set
        # 1つの経路の中の役割は、そろって要るというだけで並びに意味が無い。画面はチェックの並び(役割の名前順)で
        # 送り返すので、並びだけの違いを「直した」とすると、触っていない規則に確認済みの印が付いてしまう。
        return value.map(&:sort) == Array(current).map { |path| Array(path).sort } if kind == :paths
        return sorted_conditions(value) == sorted_conditions(current) if %i[options conditions].include?(kind)

        value == baseline(kind, field, current)
      end

      # 入れ子の条件の中の「数える区分」も、並びに意味が無い(画面は便覧の区分の並びで送り返すので、
      # 規則に書かれた並びと違うことがある)。中身を見比べるときだけ並べ替える。保存する値の並びは変えない。
      def sorted_conditions(conditions)
        Array(conditions).map do |condition|
          next condition unless condition.is_a?(Hash)

          condition.to_h do |field, value|
            next [field, sorted_conditions(value)] if field == 'conditions'

            [field, value.is_a?(Array) ? value.sort : value]
          end
        end
      end

      # 画面が送り返してくる形に直した、いまの値。
      def baseline(kind, field, current)
        case kind
        when :text, :optional_text then current.is_a?(String) ? normalize(current) : current
        when :list, :paths, :options, :conditions then Array(current)
        when :flag then current.nil? ? FLAG_DEFAULTS.fetch(field, false) : current
        else current
        end
      end
    end
  end
end

