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
    # faculty_name・department_name は、人が読む学部名・学科コース名(プルダウンの選択肢の元)。
    # department は slug(機械用の識別名)で別物。
    TOP_LEVEL_KEYS = %w[format_version department admission_year title faculty_name department_name sources categories
                        rules display courses roles].freeze
    SOURCE_KEYS = %w[id title url local_path pages note].freeze
    # number_patterns は、科目表に載っていない科目を科目番号で区分に振り分けるための欄(共通教育の科目表を
    # 便覧が持たない年度がある)。公開で落とすと、取り込んだ便覧では判定がパターンを使えないまま学生に出る。
    CATEGORY_KEYS = %w[key label counts_toward_total number_patterns].freeze
    COURSE_KEYS = %w[key number name credits category required language roles source source_page review_reason
                     requires_approval selectable].freeze
    RULE_DRAFT_KEYS = %w[confirmed].freeze
    NESTED_RULES = GraduationAssessment::Catalogue::NESTED_RULES

    class << self
      # 下書きの document を、公開する形にして返す(元は変えない)。slug・入学年度は、便覧の行が正本。
      # 文書の department・admission_year が違っても、学生が便覧を引くのは行の値なので、行に合わせる。
      # 学部名・学科コース名も、便覧の行の列が正本(画面から作った便覧も、ファイルから seed した便覧と同じ形になる)。
      # 行に無いとき(古い行)は、文書に書かれた値をそのまま残す。
      # 無い欄は無いまま(null を足すと、Catalogue は「欄はあるが配列でない」と見て読み込みを拒む)。
      def build(document, slug:, admission_year:, faculty_name: nil, department_name: nil)
        return document unless document.is_a?(Hash)

        clean = document.slice(*TOP_LEVEL_KEYS).deep_dup
        clean['department'] = slug
        clean['admission_year'] = admission_year
        clean['faculty_name'] = faculty_name if faculty_name.present?
        clean['department_name'] = department_name if department_name.present?
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

