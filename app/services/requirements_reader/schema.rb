# frozen_string_literal: true

class RequirementsReader
  # Gemini に返させる形。欄の名前は便覧の format 2(GraduationAssessment::Rules と CurriculumLayout が読むもの)に合わせる。
  # 入れ子の規則は any_of → all_of の2段まで(判定が許す深さと同じ)。
  module Schema
    STRING = { type: 'string' }.freeze
    NUMBER = { type: 'number' }.freeze
    INTEGER = { type: 'integer' }.freeze
    BOOLEAN = { type: 'boolean' }.freeze
    # 科目表にある欄のうち、グループ分けに使えるもの。
    GROUP_BY = { type: 'string', enum: %w[field:provider field:language], nullable: true }.freeze

    module_function

    def call
      object({ categories: array(keyed), roles: array(keyed), rules: array(rule), display: display },
             required: %i[categories roles rules display])
    end

    def object(properties, required:) = { type: 'object', properties: properties, required: required }
    def array(items) = { type: 'array', items: items }
    def nullable(schema) = schema.merge(nullable: true)
    def enum(values) = { type: 'string', enum: values }

    def keyed
      object({ key: STRING, label: STRING }, required: %i[key label])
    end

    # 単位を数える条件(credit_sum・grouped_max)の欄。入れ子の中でも使う。
    def credit_properties
      { categories: nullable(array(STRING)), category: nullable(STRING), required_credits: nullable(NUMBER),
        group_by: GROUP_BY, missing_group_note: nullable(STRING) }
    end

    def condition
      object(credit_properties.merge(type: enum(%w[credit_sum grouped_max])), required: %i[type])
    end

    def option
      object(credit_properties.merge(type: enum(%w[credit_sum grouped_max all_of]),
                                     conditions: nullable(array(condition))), required: %i[type])
    end

    def rule
      properties = credit_properties.merge(
        id: STRING, label: STRING, detail: nullable(STRING),
        type: enum(%w[credit_sum grouped_max one_of_paths all_required any_of cap exclude]),
        paths: nullable(array(array(STRING))), review_note: nullable(STRING),
        expected_course_count: nullable(INTEGER), required_categories: nullable(array(STRING)),
        options: nullable(array(option)), credits: nullable(NUMBER), reason: nullable(STRING),
        field: nullable(STRING), value: nullable(STRING)
      )
      object(properties, required: %i[id type label])
    end

    def display
      object({ total_credits: nullable(NUMBER), groups: array(group) }, required: %i[groups])
    end

    def group
      object({ id: STRING, title: STRING, required_credits: nullable(NUMBER), check_id: nullable(STRING),
               rows: array(row) }, required: %i[id title rows])
    end

    def row
      object({ id: STRING, name: STRING, subtitle: nullable(STRING), required_credits: nullable(NUMBER),
               required_label: nullable(STRING), categories: array(STRING), check_ids: array(STRING),
               credits_from_check: BOOLEAN },
             required: %i[id name categories check_ids credits_from_check])
    end
  end
end

