# frozen_string_literal: true

class CurriculumReader
  # 答えの形の検査。Schemas が書くスキーマ(type・properties・required・items・enum・nullable だけを使う)に当てはめる。
  # プロバイダがスキーマを守らせたかどうかには頼らない。窓口が自分で確かめる。
  module Shape
    TYPE_NAMES = { 'string' => '文字列', 'number' => '数', 'integer' => '整数', 'boolean' => '真偽' }.freeze
    TYPE_CHECKS = {
      'string' => ->(value) { value.is_a?(String) },
      'number' => ->(value) { value.is_a?(Numeric) && value.to_f.finite? },
      'integer' => ->(value) { value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.floor) },
      'boolean' => ->(value) { [true, false].include?(value) }
    }.freeze

    # 検査に引っかかった箇所の一覧(空なら合格)。答えの中身(文字列の値)はメッセージに入れない。
    def self.problems(value, schema, path = '$')
      return [] if value.nil? && schema[:nullable]
      return ["#{path} が null です"] if value.nil?

      case schema[:type]
      when 'object' then object_problems(value, schema, path)
      when 'array' then array_problems(value, schema, path)
      else scalar_problems(value, schema, path)
      end
    end

    def self.object_problems(value, schema, path)
      return ["#{path} がオブジェクトではありません"] unless value.is_a?(Hash)

      properties = schema.fetch(:properties).transform_keys(&:to_s)
      problems = key_problems(value, properties.keys, Array(schema[:required]).map(&:to_s), path)
      properties.each do |key, child|
        problems.concat(problems(value[key], child, "#{path}.#{key}")) if value.key?(key)
      end
      problems
    end

    def self.key_problems(value, allowed, required, path)
      unknown = (value.keys - allowed).first(3).map { |key| "#{path} に未知の欄 #{key.to_s.first(30)} があります" }
      missing = required.reject { |key| value.key?(key) }.map { |key| "#{path}.#{key} がありません" }
      unknown + missing
    end

    def self.array_problems(value, schema, path)
      return ["#{path} が配列ではありません"] unless value.is_a?(Array)

      value.each_with_index.flat_map { |item, index| problems(item, schema.fetch(:items), "#{path}[#{index}]") }
    end

    def self.scalar_problems(value, schema, path)
      type = schema[:type]
      return ["#{path} は#{TYPE_NAMES.fetch(type)}でなければなりません"] unless TYPE_CHECKS.fetch(type).call(value)
      return [] if schema[:enum].nil? || schema[:enum].include?(value)

      ["#{path} が許された値ではありません"]
    end

    private_class_method :object_problems, :key_problems, :array_problems, :scalar_problems
  end
end

