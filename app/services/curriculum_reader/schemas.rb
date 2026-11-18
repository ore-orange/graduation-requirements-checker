# frozen_string_literal: true

class CurriculumReader
  # AIに返させる形(JSON Schema の一部)。Gemini などの OpenAPI 風の書き方でも通るよう、
  # type・properties・required・items・enum・nullable だけを使う。型の綴りの違いは、プロバイダ側で直す。
  #
  # 欄の名前と型は、GraduationAssessment::Catalogue が便覧に求めるものに合わせる(test で突き合わせている)。
  # key・source・source_page・selectable は、ページから読むものではないので聞かない。
  # 呼び出し側が、ページの番号や既定値と一緒に付ける。
  # requires_approval(履修登録に指導教員の承認が要るか)は、便覧が印字している規則なので読む。
  # 読まないのは「学生が承認を得たか」で、それは学生ごとの事実で、便覧にはない。
  module Schemas
    STRING = { type: 'string' }.freeze
    NUMBER = { type: 'number' }.freeze
    BOOLEAN = { type: 'boolean' }.freeze
    INTEGER = { type: 'integer' }.freeze
    # grouped_max のグループの分け方。Ledger が解釈できるものだけ(知らない値は、学生の判定の最中に KeyError になる)。
    GROUP_BY = { type: 'string',
                 enum: [*GraduationAssessment::Ledger::NUMBER_GROUPERS.keys,
                        "#{GraduationAssessment::Ledger::FIELD_GROUP}language"] }.freeze

    # 型ごとに、規則に必ず要る欄。欄が無い・null の規則は、読み取りの失敗にする。
    RULE_REQUIRED = {
      'credit_sum' => %w[categories required_credits],
      'all_required' => %w[expected_course_count required_credits required_categories],
      'one_of_paths' => %w[paths],
      'grouped_max' => %w[category group_by required_credits],
      'any_of' => %w[options],
      'cap' => %w[category credits],
      'exclude' => %w[category reason]
    }.merge('all_of' => %w[conditions]).freeze

    class << self
      def requirements
        object({ categories: array(category), roles: array(role), rules: array(rule), display: display },
               required: %i[categories roles rules display])
      end

      # 科目の区分は category_keys のどれかに限る(空にはできない。呼び出し側が先に区分を決めておく)。
      # role_keys が空でなければ、科目は roles(その一覧から0個以上)を持つ。空なら roles の欄を聞かない(空の enum は書けないため)。
      def courses(category_keys, role_keys = [])
        category_schema = { type: 'string', enum: category_keys }
        object({ courses: array(course(category_schema, role_keys)) }, required: %i[courses])
      end

      private

      def object(properties, required:)
        { type: 'object', properties: properties, required: required }
      end

      def array(items) = { type: 'array', items: items }

      def nullable(schema) = schema.merge(nullable: true)

      def category
        object({ key: STRING, label: STRING, counts_toward_total: BOOLEAN },
               required: %i[key label counts_toward_total])
      end

      # 入れ子の規則は2段まで(any_of の下の選択肢、all_of の下の条件)。Catalogue と Rules が許す深さと同じ。
      def leaf_properties
        { type: STRING, category: nullable(STRING), categories: nullable(array(STRING)), group_by: nullable(GROUP_BY),
          group_label: nullable(STRING), required_credits: nullable(NUMBER) }
      end

      def condition
        object(leaf_properties.merge(type: { type: 'string', enum: %w[credit_sum grouped_max] }), required: %i[type])
      end

      def option
        properties = leaf_properties.merge(type: { type: 'string', enum: %w[credit_sum grouped_max all_of] },
                                           conditions: nullable(array(condition)))
        object(properties, required: %i[type])
      end

      def rule
        properties = leaf_properties.merge(
          id: STRING, label: STRING, detail: nullable(STRING),
          type: { type: 'string', enum: %w[credit_sum all_required one_of_paths grouped_max any_of cap exclude] },
          credits: nullable(NUMBER), expected_course_count: nullable(INTEGER),
          required_categories: nullable(array(STRING)), paths: nullable(array(array(STRING))),
          number_prefix: nullable(STRING), reason: nullable(STRING), review_note: nullable(STRING),
          options: nullable(array(option))
        )
        object(properties, required: %i[id type label])
      end

      def display
        object({ total_credits: nullable(NUMBER), groups: array(group), subtotals: nullable(array(subtotal)) },
               required: %i[groups])
      end

      def group
        object({ id: STRING, title: STRING, required_credits: NUMBER, check_id: nullable(STRING), rows: array(row) },
               required: %i[id title required_credits rows])
      end

      def row
        object({ id: STRING, name: STRING, subtitle: nullable(STRING), required_credits: nullable(NUMBER),
                 required_label: nullable(STRING), categories: array(STRING), check_ids: array(STRING),
                 credits_from_check: BOOLEAN },
               required: %i[id name required_credits required_label categories check_ids credits_from_check])
      end

      def subtotal
        object({ id: STRING, name: STRING, required_credits: NUMBER, row_ids: array(STRING), check_ids: array(STRING) },
               required: %i[id name required_credits row_ids check_ids])
      end

      def course(category_schema, role_keys)
        properties = { number: nullable(STRING), name: STRING, credits: nullable(NUMBER), category: category_schema,
                       required: BOOLEAN, requires_approval: BOOLEAN, language: nullable(STRING),
                       review_reason: nullable(STRING) }
        required = %i[number name credits category required requires_approval language review_reason]
        return object(properties, required: required) if role_keys.empty?

        object(properties.merge(roles: array(type: 'string', enum: role_keys)), required: required + [:roles])
      end

      def role
        object({ key: STRING, label: STRING }, required: %i[key label])
      end
    end
  end
end

