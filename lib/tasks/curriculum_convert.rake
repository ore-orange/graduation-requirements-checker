# frozen_string_literal: true

# 旧形式（format 1）の便覧に、規則データ（format 2）の欄を足す一度きりの変換。
#
# 足すのは categories・rules・display だけで、requirements・courses（英語キー・provider・review_reason を含む）は
# 触らない。旧コードがまだそれらを読んでいるため。値は旧コードの定数・ヘルパーから読んで写すので、
# それらを消すタスク（Task 7）の後はこの変換を実行できない。
# アプリの定数は rake の読み込み時にはまだ使えないので、どれも実行時に引く。
module CurriculumConvert
  module_function

  def catalogue = GraduationAssessment::Catalogue

  def call(document)
    return document if document['format_version'] == 2

    converted = document.merge('format_version' => 2, 'categories' => categories,
                               'rules' => Rules.call(document.fetch('requirements')), 'display' => display)
    # 規則類は requirements の次、courses の前に置く。ほかの欄の順は変えない。
    converted.slice(*(converted.keys - ['courses'])).merge('courses' => converted.fetch('courses'))
  end

  def categories
    catalogue::CATEGORIES.map do |key|
      { 'key' => key, 'label' => StudentWorkspaceHelper::CATEGORY_LABELS.fetch(key),
        'counts_toward_total' => key != 'excluded' }
    end
  end

  def display
    { 'total_credits' => DashboardMetrics::GRADUATION_CREDITS,
      'groups' => StudentWorkspaceHelper::PLANNER_GROUPS.map { |group| display_group(group) },
      'subtotals' => PlansHelper::PLANNER_SUBTOTALS.map { |subtotal| display_subtotal(subtotal) } }
  end

  def display_group(group)
    { 'id' => group[:id], 'title' => group[:title], 'required_credits' => group[:req],
      'check_id' => group[:check_id], 'rows' => group[:rows].map { |row| display_row(row) } }
  end

  def display_row(row)
    { 'id' => row[:id], 'name' => row[:name], 'subtitle' => row[:subtitle], 'required_credits' => row[:req],
      'required_label' => row[:req_label], 'categories' => row[:categories], 'check_ids' => row[:check_ids],
      'credits_from_check' => DashboardMetrics::CHECK_DRIVEN_ROWS.include?(row[:id]) }
  end

  def display_subtotal(subtotal)
    { 'id' => subtotal[:id], 'name' => subtotal[:name], 'required_credits' => subtotal[:req],
      'row_ids' => subtotal[:row_ids], 'check_ids' => subtotal[:check_ids] }
  end

  # 現行の24個のチェックと、算入を変える調整3件。id・label・detail の文面は旧コードのまま。
  module Rules
    module_function

    WITHOUT_NATURAL = %w[humanities social integrated career regional].freeze

    def catalogue = GraduationAssessment::Catalogue
    def source = catalogue::SOURCE
    def required_source = catalogue::REQUIRED_SOURCE

    # 並びは旧 Evaluation が checks を作っていた順（画面に出る順）。調整は最後に置く。
    def call(requirements)
      common_rules(requirements) + basic_rules(requirements) + specialist_rules + [total_rule] + adjustment_rules
    end

    def credit_sum(id, label, categories, required, **options)
      { 'id' => id, 'type' => 'credit_sum', 'label' => label, 'categories' => categories,
        'required_credits' => required, 'source_page' => options.fetch(:source, source),
        'detail' => options.fetch(:detail, '') }
    end

    def one_of_paths(id, label, paths, review_note: nil)
      { 'id' => id, 'type' => 'one_of_paths', 'label' => label, 'paths' => paths,
        'review_note' => review_note, 'source_page' => source }.compact
    end

    def common_rules(requirements)
      general_rules + [
        one_of_paths('japanese', '日本語表現法入門', [[requirements.fetch('japanese_role')]]),
        one_of_paths('english_required', '指定英語科目', [requirements.fetch('english_roles')]),
        foreign_language_rule,
        credit_sum('common_total', '共通教育の合計', catalogue::COMMON, 30)
      ]
    end

    def general_rules
      [
        credit_sum('health', '健康運動系', ['health'], 2),
        credit_sum('humanities', '人文系', ['humanities'], 2),
        credit_sum('social', '社会系', ['social'], 2),
        credit_sum('general_integrated', '総合・キャリア・琉大特色／地域創生', %w[integrated career regional], 2,
                   detail: '3区分の合計。各区分それぞれ2単位ではありません。'),
        credit_sum('general_without_natural', '自然系を除く教養・総合領域', WITHOUT_NATURAL, 12),
        credit_sum('general_subtotal', '教養・総合領域の小計', WITHOUT_NATURAL + ['natural'], 14,
                   detail: '健康運動系は含めず、自然系は最大2単位。')
      ]
    end

    # 英語12単位、または 英語8単位＋同じ一外国語4単位。一外国語は科目の language 欄で見分ける。
    # 科目番号の百の位では分けない（外7xx はインドネシア語・タイ語・ラテン語・ロシア語が混ざる）。
    # 旧コードは英語・一外国語の最大単位を文の前に付けていた。データには説明の部分だけを置く。
    # required_credits は持たない（旧チェックも nil）。
    def foreign_language_rule
      { 'id' => 'foreign_language', 'type' => 'any_of', 'label' => '外国語の選択経路', 'options' => [
        { 'type' => 'credit_sum', 'categories' => ['english'], 'required_credits' => 12 },
        { 'type' => 'all_of', 'conditions' => [
          { 'type' => 'credit_sum', 'categories' => ['english'], 'required_credits' => 8 },
          { 'type' => 'grouped_max', 'category' => 'foreign_language', 'group_by' => 'field:language',
            'group_label' => '言語', 'required_credits' => 4 }
        ] }
      ], 'source_page' => source, 'detail' => '英語12単位、または英語8単位＋同じ一外国語4単位。指定英語科目は別途必須。' }
    end

    def basic_rules(requirements)
      [
        credit_sum('basic_total', '専門基礎教育の合計', ['basic'], 6),
        one_of_paths('calculus', '微分積分学の指定系列', requirements.fetch('calculus_paths'),
                     review_note: '微分積分学の系列が混在・重複しており、組合せと重複算入の確認が必要'),
        one_of_paths('physics', '物理学の指定科目', requirements.fetch('physics_roles').zip,
                     review_note: '物理学の代替科目を重複して修得・予定しており、重複算入の確認が必要')
      ]
    end

    def specialist_rules
      [required_all_rule] + required_group_rules + [
        credit_sum('required_total', '専門必修の合計', catalogue::REQUIRED.keys, 57, source: required_source),
        credit_sum('elective_inner', '数学基礎選択＋アドバンスト＋関連', catalogue::INNER, 22,
                   detail: '専門選択37単位の内数。工学融合・自由科目はこの22単位に含めません。'),
        credit_sum('elective_total', '専門選択の合計', catalogue::ELECTIVE, 37),
        fusion_provider_rule
      ]
    end

    # 前段の「31科目それぞれの修得を確認。…」はコードが expected_course_count から組む。
    def required_all_rule
      { 'id' => 'required_all', 'type' => 'all_required', 'label' => '専門必修31科目すべて',
        'expected_course_count' => 31, 'required_credits' => 57, 'source_page' => required_source,
        'detail' => '余剰単位による代用は不可。' }
    end

    def required_group_rules
      catalogue::REQUIRED.map do |category, (label, credits)|
        credit_sum(category, label, [category], credits, source: required_source)
      end
    end

    # 自コース提供分は exclude 規則で算入されないので、残った提供コースのうち最大を見る。提供コースは科目番号の接頭辞で分ける。
    def fusion_provider_rule
      { 'id' => 'fusion_provider', 'type' => 'grouped_max', 'label' => '同一の他コースが提供する工学融合',
        'category' => 'fusion', 'group_by' => 'number_prefix', 'required_credits' => 4, 'source_page' => source,
        'detail' => '自コース提供分は不可。他コースを合算せず、同一提供コースから4単位以上。' }
    end

    def total_rule
      credit_sum('total', '卒業算入総単位', catalogue::CATEGORIES - ['excluded'], 130,
                 detail: '共通教育＋専門基礎＋専門必修＋専門選択。自然系は全体でも上限2単位。')
    end

    # cap は label を持たない。区分名は categories から引く。
    def adjustment_rules
      [
        { 'id' => 'natural_cap', 'type' => 'cap', 'category' => 'natural', 'credits' => 2, 'source_page' => source },
        { 'id' => 'excluded_category', 'type' => 'exclude', 'category' => 'excluded',
          'reason' => '卒業単位への算入対象外', 'source_page' => source },
        { 'id' => 'own_fusion', 'type' => 'exclude', 'category' => 'fusion', 'number_prefix' => '知能',
          'reason' => '自コース提供の工学融合科目は登録・算入不可', 'source_page' => source }
      ]
    end
  end
end

namespace :curriculum do
  desc '旧形式の便覧に規則データ（format 2）を足す。curriculum:convert[config/curricula/intelligent_informatics/2024.json]'
  task :convert, [:path] => :environment do |_task, args|
    path = Rails.root.join(args.fetch(:path) { abort '便覧のパスを渡してください: curriculum:convert[path]' })
    document = JSON.parse(path.read)
    version = document['format_version']
    abort "#{path} は format #{version} です。変換できるのは format 1 と 2 だけです" unless [1, 2].include?(version)

    converted = CurriculumConvert.call(document)
    path.write("#{JSON.pretty_generate(converted)}\n")
    puts "wrote #{path} (format_version #{converted['format_version']}, rules #{converted['rules'].size}, " \
         "courses #{converted['courses'].size})"
  end
end

