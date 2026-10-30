# frozen_string_literal: true

# 要件表の確認画面・読み直しの保護のテストが使う、人工の下書きの文書。
# 突き合わせ(Validation)には何も指摘されない形にしてあり、壊すときは1か所だけ変える。
module RequirementsDraftFixtures
  def fixture_course(number, name, category, **fields)
    { 'key' => "course_#{number}", 'number' => number, 'name' => name, 'credits' => 2, 'category' => category,
      'required' => false, 'language' => nil, 'roles' => [], 'source' => 'handbook', 'source_page' => 'PDF3ページ',
      'review_reason' => nil, 'requires_approval' => false, 'selectable' => true }.merge(fields.stringify_keys)
  end

  def fixture_rule(id, type, **fields)
    { 'id' => id, 'type' => type, 'label' => "規則#{id}", 'source_page' => 'PDF3ページ' }.merge(fields.stringify_keys)
  end

  def fixture_row(id, categories, check_ids, required, **fields)
    { 'id' => id, 'name' => "行#{id}", 'subtitle' => nil, 'required_credits' => required, 'required_label' => nil,
      'categories' => categories, 'check_ids' => check_ids, 'credits_from_check' => false }.merge(fields.stringify_keys)
  end

  def requirements_document
    { 'format_version' => 2, 'department' => 'sample', 'admission_year' => 2025, 'title' => '見本',
      'categories' => fixture_categories, 'courses' => fixture_courses, 'rules' => fixture_rules,
      'display' => fixture_display }
  end

  def fixture_categories
    [['humanities', '人文系', true], ['english', '英語', true], ['required_core', 'コア必修', true],
     ['fusion', '工学融合', true], ['excluded', '算入対象外', false]].map do |key, label, counts|
      { 'key' => key, 'label' => label, 'counts_toward_total' => counts }
    end
  end

  def fixture_courses
    [fixture_course('人101', '哲学', 'humanities', roles: ['role_a']),
     fixture_course('人102', '倫理', 'humanities', roles: ['role_b']), fixture_course('人103', '歴史', 'humanities'),
     fixture_course('外101', '英語Ⅰ', 'english'), fixture_course('外102', '英語Ⅱ', 'english'),
     fixture_course('知能101', 'プログラミング', 'required_core', required: true),
     fixture_course('知能102', '離散数学', 'required_core', required: true),
     fixture_course('機械991', '熱力学', 'fusion'), fixture_course('機械992', '流体力学', 'fusion'),
     fixture_course('情01', '情報科学演習', 'excluded', selectable: false)]
  end

  def fixture_rules
    categories = %w[humanities english required_core fusion]
    [fixture_rule('humanities', 'credit_sum', categories: ['humanities'], required_credits: 4),
     fixture_rule('english', 'credit_sum', categories: ['english'], required_credits: 2),
     fixture_rule('path_rule', 'one_of_paths', paths: [['role_a'], ['role_b']]),
     fixture_rule('core', 'all_required', expected_course_count: 2, required_credits: 4,
                                          required_categories: ['required_core']),
     fixture_rule('fusion_provider', 'grouped_max', category: 'fusion', group_by: 'number_prefix', required_credits: 4),
     fixture_rule('total', 'credit_sum', categories: categories, required_credits: 14),
     fixture_rule('excluded_category', 'exclude', category: 'excluded', reason: '算入対象外')]
  end

  def fixture_display
    { 'total_credits' => 14,
      'groups' => [{ 'id' => 'common', 'title' => '1. 共通教育', 'required_credits' => 6,
                     'rows' => [fixture_row('humanities', ['humanities'], ['humanities'], 4),
                                fixture_row('english', ['english'], ['english'], 2)] },
                   { 'id' => 'required', 'title' => '2. 必修', 'required_credits' => 4, 'check_id' => 'core',
                     'rows' => [fixture_row('required_core', ['required_core'], ['core'], 4)] },
                   { 'id' => 'elective', 'title' => '3. 選択', 'required_credits' => 4,
                     'rows' => [fixture_row('fusion', ['fusion'], ['fusion_provider'], 4,
                                            credits_from_check: true)] }] }
  end
end

# 要件表の確認画面を、統合テストから開く・保存する道具。ActionDispatch::IntegrationTest に include する。
module RequirementsScreenHelpers
  ENV_LOCAL = { 'REMOTE_ADDR' => '127.0.0.1' }.freeze

  # 要件表のページ(2)を読み終えた下書き。そのページが足したものを contributed に持つ。
  def draft(document: requirements_document, extra_pages: [])
    contributed = { 'rules' => Array(document['rules']).grep(Hash).pluck('id'),
                    'groups' => document.dig('display', 'groups').grep(Hash).pluck('id'), 'subtotals' => [],
                    'total_credits' => true }
    pages = [{ 'page' => 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => '表紙' },
             { 'page' => 2, 'kind' => 'requirements', 'status' => 'read', 'error' => nil, 'text' => '要件',
               'contributed' => contributed }] + extra_pages
    Curriculum.create!(slug: 'x', admission_year: 2025, faculty_name: '工学部', department_name: '工学科 知能情報コース',
                       source_filename: 'handbook.pdf', pages: pages, document: document)
  end

  def show(draft) = get(curriculum_path(draft), env: ENV_LOCAL)

  def revision_of(draft) = CurriculumImport::RequirementsEdit.revision(draft.reload.document)

  def save(draft, with_revision: true, **params)
    params = params.merge(revision: revision_of(draft)) if with_revision
    patch update_rules_curriculum_path(draft), params: params, env: ENV_LOCAL
  end

  def groups(draft) = draft.reload.document['display']['groups']

  def group(draft, id) = groups(draft).find { |entry| entry['id'] == id }

  def rule(draft, id) = draft.reload.document['rules'].find { |entry| entry['id'] == id }

  def card_id(draft, kind)
    CurriculumImport::Annotations.cards(draft.reload.document, draft.pages).find { |card| card.kind == kind }.id
  end

  # 画面のフォームを、ブラウザと同じように送り返す(入力欄・チェック済みの箱・選択・テキストエリアの中身)。
  # 触らずに送り返したとき、何も「直した」ことにならないこと(確認の印が付かないこと)を、実物の画面で確かめるため。
  def browser_pairs(draft)
    get curriculum_path(draft), env: ENV_LOCAL
    form = response.parsed_body.at_css('#requirements_form')
    form.css('input, textarea, select').filter_map { |field| browser_value(field) }
  end

  def browser_value(field)
    name = field['name']
    return if name.blank? || field['type'] == 'submit' || %w[_method authenticity_token].include?(name)
    return if %w[checkbox radio].include?(field['type']) && field['checked'].nil?

    [name, browser_field_value(field)]
  end

  def browser_field_value(field)
    case field.name
    when 'textarea' then field.text.delete_prefix("\n")
    when 'select' then field.at_css('option[selected]')&.[]('value').to_s
    else field['value'].to_s
    end
  end

  def submit_pairs(draft, pairs)
    patch update_rules_curriculum_path(draft), params: URI.encode_www_form(pairs),
                                               headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' },
                                               env: ENV_LOCAL
  end
end

