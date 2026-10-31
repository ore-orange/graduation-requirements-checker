# frozen_string_literal: true

module CurriculumImport
  # 公開する便覧の中身。下書きの document から、確認画面が足した作業用の欄を落とし、公開済みの便覧が持つ欄だけにする。
  # 「公開した便覧は何を持つか」は、ここ1か所で決める(公開の関門も、複製して直すのも、ここを通る)。
  #
  # 持てる欄は、実物の config/curricula/intelligent_informatics/2024.json が持つ欄と同じ。
  #  - 閉じた語彙(最上位・科目・区分・出典・画面の表)は、持てる欄だけを残す(許可する側)。確認画面が将来欄を足しても、
  #    公開した便覧には黙って混ざらない。画面の表の語彙は Catalogue が持つ(読み取りの形と同じ定数で、ここに写さない)。
  #  - 規則は型ごとに欄が違い、語彙が開いている。許可する側で書くと、型に欄を足したとき公開で黙って落ちて判定が変わるので、
  #    作業用の欄(confirmed)だけを名指しで落とす(入れ子の options・conditions の中も)。
  #
  # 落とす欄(下書きだけが持つ)。科目: confirmed・read_as・read_fp・added_by_hand・approval_by_note・review_again。
  # 区分・規則・章・行・小計: confirmed。最上位: approval_notes・removed_by_human・annotation_decisions。
  # review_reason は、学生の画面に「要確認」として出る欄なので残す。
  module PublishedDocument
    TOP_LEVEL_KEYS = %w[format_version department admission_year title sources categories rules display courses
                        roles].freeze
    SOURCE_KEYS = %w[id title url local_path pages note].freeze
    CATEGORY_KEYS = %w[key label counts_toward_total].freeze
    COURSE_KEYS = %w[key number name credits category required language roles source source_page review_reason
                     requires_approval selectable].freeze
    RULE_DRAFT_KEYS = %w[confirmed].freeze
    NESTED_RULES = GraduationAssessment::Catalogue::NESTED_RULES

    class << self
      # 下書きの document を、公開する形にして返す(元は変えない)。slug・入学年度は、便覧の行が正本。
      # 文書の department・admission_year が違っても、学生が便覧を引くのは行の値なので、行に合わせる。
      # 無い欄は無いまま(null を足すと、Catalogue は「欄はあるが配列でない」と見て読み込みを拒む)。
      def build(document, slug:, admission_year:)
        return document unless document.is_a?(Hash)

        clean = document.slice(*TOP_LEVEL_KEYS).deep_dup
        clean['department'] = slug
        clean['admission_year'] = admission_year
        replace(clean, 'sources') { |list| pick(list, SOURCE_KEYS) }
        replace(clean, 'categories') { |list| pick(list, CATEGORY_KEYS) }
        replace(clean, 'courses') { |list| pick(list, COURSE_KEYS) }
        replace(clean, 'rules') { |list| rules(list) }
        replace(clean, 'display') { |display| display(display) }
        clean
      end

      private

      def replace(hash, key)
        hash[key] = yield(hash[key]) if hash.key?(key)
      end

      def display(value)
        return value unless value.is_a?(Hash)

        catalogue = GraduationAssessment::Catalogue
        shown = value.slice(*catalogue::DISPLAY_KEYS)
        replace(shown, 'groups') { |list| groups(list, catalogue) }
        replace(shown, 'subtotals') { |list| pick(list, catalogue::DISPLAY_SUBTOTAL_KEYS) }
        shown
      end

      def groups(list, catalogue)
        return list unless list.is_a?(Array)

        list.map do |group|
          next group unless group.is_a?(Hash)

          group.slice(*catalogue::DISPLAY_GROUP_KEYS).tap do |shown|
            replace(shown, 'rows') { |rows| pick(rows, catalogue::DISPLAY_ROW_KEYS) }
          end
        end
      end

      def rules(value)
        return value unless value.is_a?(Array)

        value.map { |rule| rule.is_a?(Hash) ? rule_without_draft_keys(rule) : rule }
      end

      def rule_without_draft_keys(rule)
        rule = rule.except(*RULE_DRAFT_KEYS)
        NESTED_RULES.each { |field| replace(rule, field) { |nested| rules(nested) } }
        rule
      end

      # 配列の各要素から、持てる欄だけを残す。配列でない値・ハッシュでない要素は、そのまま(関門が形の問題として止める)。
      def pick(value, keys)
        return value unless value.is_a?(Array)

        value.map { |item| item.is_a?(Hash) ? item.slice(*keys) : item }
      end
    end
  end
end

