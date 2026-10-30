# frozen_string_literal: true

require 'test_helper'

class CurriculumReaderTest < ActiveSupport::TestCase
  # 実際のAPIには触れない。窓口に渡すのは、決めた答えを返すだけの偽のクライアント。
  class StubClient
    attr_reader :calls, :last

    def initialize(answers = nil, &block)
      @answers = answers.is_a?(Array) ? answers.dup : [answers]
      @block = block
      @calls = 0
    end

    def generate(prompt:, image_path:, schema:)
      @calls += 1
      @last = { prompt: prompt, image_path: image_path, schema: schema }
      answer = @block ? @block.call(prompt, image_path, schema) : @answers.shift
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  EMPTY_COURSES = { 'courses' => [] }.freeze

  def reader(client, sleeps: [])
    CurriculumReader.new(client: client, sleeper: ->(seconds) { sleeps << seconds })
  end

  def read_courses(client, categories: [], **)
    reader(client, **).read_courses(text: 't', image_path: nil, categories: categories)
  end

  def failure(status) = CurriculumReader::RequestFailed.new("HTTP #{status}", status: status)

  def with_key(value)
    original = ENV.fetch('CURRICULUM_READER_API_KEY', nil)
    value ? ENV['CURRICULUM_READER_API_KEY'] = value : ENV.delete('CURRICULUM_READER_API_KEY')
    yield
  ensure
    original ? ENV['CURRICULUM_READER_API_KEY'] = original : ENV.delete('CURRICULUM_READER_API_KEY')
  end

  def course(overrides = {})
    { 'number' => '知能101', 'name' => 'プログラミング演習Ⅰ', 'credits' => 1, 'category' => 'a',
      'required' => true, 'language' => nil, 'review_reason' => nil }.merge(overrides)
  end

  def requirements_answer
    { 'categories' => [{ 'key' => 'health', 'label' => '健康運動系', 'counts_toward_total' => true }],
      'rules' => [{ 'id' => 'health', 'type' => 'credit_sum', 'label' => '健康運動系', 'categories' => ['health'],
                    'required_credits' => 2 }],
      'display' => { 'total_credits' => 130, 'groups' => [] } }
  end

  # --- 使えるかどうか

  test 'APIキーがなければ使えないと答える' do
    with_key(nil) { assert_not CurriculumReader.available? }
    with_key('') { assert_not CurriculumReader.available? }
  end

  test 'APIキーがあれば使えると答える' do
    with_key('dummy-key') { assert CurriculumReader.available? }
  end

  # --- プロンプトの中身

  test '科目表のプロンプトには確定した区分の一覧が入る' do
    client = StubClient.new(EMPTY_COURSES)
    read_courses(client, categories: %w[course_required fusion])

    assert_includes client.last[:prompt], 'course_required'
    assert_includes client.last[:prompt], 'fusion'
  end

  test '区分が{key, label}のハッシュで渡されても、keyとlabelの両方がプロンプトに入る' do
    client = StubClient.new(EMPTY_COURSES)
    read_courses(client, categories: [{ 'key' => 'fusion', 'label' => '工学融合科目' }])

    assert_includes client.last[:prompt], 'fusion'
    assert_includes client.last[:prompt], '工学融合科目'
  end

  test '科目表の出力スキーマは、区分を渡された一覧に限る' do
    client = StubClient.new(EMPTY_COURSES)
    read_courses(client, categories: %w[a b])

    category = client.last[:schema].dig(:properties, :courses, :items, :properties, :category)
    assert_equal %w[a b], category[:enum]
  end

  test 'どちらのプロンプトも、画像が正でテキストは補助だと伝える' do
    requirements = StubClient.new(requirements_answer)
    reader(requirements).read_requirements(text: 't', image_path: nil)
    courses = StubClient.new(EMPTY_COURSES)
    read_courses(courses)

    [requirements, courses].each do |client|
      assert_includes client.last[:prompt], '画像が正'
      assert_includes client.last[:prompt], '黙って'
    end
  end

  test 'どちらのプロンプトも、並んだ表ではテキストが混ざり、境は画像でしか分からないと伝える' do
    requirements = StubClient.new(requirements_answer)
    reader(requirements).read_requirements(text: 't', image_path: nil)
    courses = StubClient.new(EMPTY_COURSES)
    read_courses(courses)

    [requirements, courses].each do |client|
      assert_includes client.last[:prompt], '左右に並'
      assert_includes client.last[:prompt], '別々の表のセルが混ざる'
    end
  end

  test 'ページのテキストと画像の場所がそのままクライアントに渡る' do
    client = StubClient.new(EMPTY_COURSES)
    reader(client).read_courses(text: '知能101 プログラミング演習Ⅰ', image_path: '/x/p3.png', categories: [])

    assert_includes client.last[:prompt], '知能101 プログラミング演習Ⅰ'
    assert_equal '/x/p3.png', client.last[:image_path]
  end

  test 'テキストが空のときは、取り出せなかったと伝える' do
    client = StubClient.new(EMPTY_COURSES)
    reader(client).read_courses(text: nil, image_path: '/x/p3.png', categories: [])

    assert_includes client.last[:prompt], '取り出せませんでした'
  end

  # --- 正しい答え

  test '要件表の答えは categories と rules と display を返す' do
    result = reader(StubClient.new(requirements_answer)).read_requirements(text: 't', image_path: nil)

    assert_equal %w[categories display rules], result.keys.sort
    assert_equal 'health', result['categories'].first['key']
    assert_equal 130, result['display']['total_credits']
  end

  test '規則の null の欄は落とす(欄が無いのと同じにして、規則の読み込みで型が崩れないようにする)' do
    answer = requirements_answer
    answer['rules'][0].merge!('detail' => nil, 'credits' => nil, 'number_prefix' => nil)
    result = reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil)

    assert_equal %w[categories id label required_credits type], result['rules'][0].keys.sort
  end

  test '表示の行は、必要単位とラベルの null を残す(null は内数の行という意味を持つ)' do
    answer = requirements_answer
    answer['display']['groups'] = [{ 'id' => 'g', 'title' => '1. 共通', 'required_credits' => 30, 'check_id' => nil,
                                     'rows' => [{ 'id' => 'r', 'name' => '行', 'subtitle' => nil,
                                                  'required_credits' => nil, 'required_label' => '内数',
                                                  'categories' => [], 'check_ids' => [],
                                                  'credits_from_check' => false }] }]
    group = reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil)['display']['groups'][0]

    assert_not group.key?('check_id')
    assert_nil group['rows'][0]['required_credits']
    assert group['rows'][0].key?('required_credits')
    assert_not group['rows'][0].key?('subtitle')
  end

  test '科目表の答えは courses を返す' do
    result = read_courses(StubClient.new('courses' => [course]), categories: %w[a])

    assert_equal [course], result['courses']
  end

  test 'any_of の入れ子の規則も通る' do
    answer = requirements_answer
    answer['rules'] << { 'id' => 'foreign_language', 'type' => 'any_of', 'label' => '外国語',
                         'options' => [{ 'type' => 'credit_sum', 'categories' => ['english'],
                                         'required_credits' => 12 },
                                       { 'type' => 'all_of',
                                         'conditions' => [{ 'type' => 'credit_sum', 'categories' => ['english'],
                                                            'required_credits' => 8 },
                                                          { 'type' => 'grouped_max', 'category' => 'fl',
                                                            'group_by' => 'field:language',
                                                            'required_credits' => 4 }] }] }
    result = reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil)

    assert_equal 2, result['rules'].size
  end

  # --- 再試行

  test '429 は待って数回やり直す' do
    client = StubClient.new([failure(429), failure(429), EMPTY_COURSES])

    assert_equal EMPTY_COURSES, read_courses(client)
    assert_equal 3, client.calls
  end

  test '5xx もやり直す' do
    client = StubClient.new([failure(503), failure(500), EMPTY_COURSES])

    assert_equal EMPTY_COURSES, read_courses(client)
    assert_equal 3, client.calls
  end

  test '通信の失敗(状態コードなし)もやり直す' do
    client = StubClient.new([CurriculumReader::RequestFailed.new('通信に失敗しました(Net::ReadTimeout)'), EMPTY_COURSES])

    assert_equal EMPTY_COURSES, read_courses(client)
    assert_equal 2, client.calls
  end

  test '待ち時間は倍々に増える' do
    sleeps = []
    read_courses(StubClient.new([failure(429), failure(429), EMPTY_COURSES]), sleeps: sleeps)

    assert_equal [CurriculumReader::BACKOFF_BASE, CurriculumReader::BACKOFF_BASE * 2], sleeps
  end

  test '再試行しても駄目なら Error。3回で諦め、最後の待ちは入れない' do
    sleeps = []
    client = StubClient.new { failure(429) }

    error = assert_raises(CurriculumReader::Error) { read_courses(client, sleeps: sleeps) }
    assert_equal CurriculumReader::MAX_ATTEMPTS, client.calls
    assert_equal CurriculumReader::MAX_ATTEMPTS - 1, sleeps.size
    assert_includes error.message, '429'
  end

  test '400 や 401・403 は、やり直しても同じなので1回で Error' do
    [400, 401, 403, 404].each do |status|
      client = StubClient.new { failure(status) }

      assert_raises(CurriculumReader::Error) { read_courses(client) }
      assert_equal 1, client.calls, "#{status} を再試行した"
    end
  end

  test '形の違う答えはやり直さない(同じ問いに別の答えを待って、使った回数を無駄にしない)' do
    client = StubClient.new { { 'rows' => [] } }

    assert_raises(CurriculumReader::Error) { read_courses(client) }
    assert_equal 1, client.calls
  end

  test '再試行の途中で成功すれば、前の失敗は結果に残らない' do
    result = read_courses(StubClient.new([failure(502), { 'courses' => [course] }]), categories: %w[a])

    assert_equal 1, result['courses'].size
  end

  # --- 答えの検査

  test '200 でも本文がJSONでなければ Error(クライアントが文字列を返した場合)' do
    assert_raises(CurriculumReader::Error) { read_courses(StubClient.new('<html>')) }
  end

  test 'クライアントが配列を返しても Error' do
    assert_raises(CurriculumReader::Error) { read_courses(StubClient.new([[]]), categories: []) }
  end

  test 'スキーマにない形が返ってきたら Error' do
    assert_raises(CurriculumReader::Error) { read_courses(StubClient.new('rows' => [])) }
  end

  test '知らない欄が混ざっていたら Error' do
    assert_raises(CurriculumReader::Error) { read_courses(StubClient.new('courses' => [], 'extra' => 1)) }
  end

  test '科目の必須の欄が欠けていたら Error' do
    assert_raises(CurriculumReader::Error) do
      read_courses(StubClient.new('courses' => [course.except('name')]), categories: %w[a])
    end
  end

  test '単位が数でなければ Error' do
    assert_raises(CurriculumReader::Error) do
      read_courses(StubClient.new('courses' => [course('credits' => '2')]), categories: %w[a])
    end
  end

  test '必修の欄が真偽でなければ Error' do
    assert_raises(CurriculumReader::Error) do
      read_courses(StubClient.new('courses' => [course('required' => 'true')]), categories: %w[a])
    end
  end

  test '渡した一覧にない区分を科目に付けたら Error(区分を作らせない)' do
    error = assert_raises(CurriculumReader::Error) do
      read_courses(StubClient.new('courses' => [course('category' => 'invented')]), categories: %w[a b])
    end
    assert_includes error.message, 'category'
  end

  test '単位と科目番号の null は許す(特別講義など、科目表に単位が無い行がある)' do
    result = read_courses(StubClient.new('courses' => [course('number' => nil, 'credits' => nil)]), categories: %w[a])

    assert_nil result['courses'][0]['credits']
  end

  test '要件表で categories が欠けていたら Error' do
    answer = requirements_answer.except('categories')

    assert_raises(CurriculumReader::Error) { reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil) }
  end

  test '知らない型の規則は Error' do
    answer = requirements_answer
    answer['rules'][0]['type'] = 'formula'

    assert_raises(CurriculumReader::Error) { reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil) }
  end

  test '型ごとに要る欄が無い規則は Error(credit_sum に必要単位が無い)' do
    answer = requirements_answer
    answer['rules'][0].delete('required_credits')
    error = assert_raises(CurriculumReader::Error) do
      reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil)
    end

    assert_includes error.message, 'required_credits'
  end

  test '型ごとに要る欄が null の規則も Error' do
    answer = requirements_answer
    answer['rules'][0]['required_credits'] = nil

    assert_raises(CurriculumReader::Error) { reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil) }
  end

  test '入れ子の規則に要る欄が無くても Error' do
    answer = requirements_answer
    answer['rules'] << { 'id' => 'fl', 'type' => 'any_of', 'label' => '外国語',
                         'options' => [{ 'type' => 'credit_sum', 'categories' => ['english'] }] }

    assert_raises(CurriculumReader::Error) { reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil) }
  end

  test '必要単位が null の行にラベルが無ければ Error(満たしていない要件が画面から消えるため)' do
    answer = requirements_answer
    answer['display']['groups'] = [{ 'id' => 'g', 'title' => '1', 'required_credits' => 30,
                                     'rows' => [{ 'id' => 'r', 'name' => '行', 'required_credits' => nil,
                                                  'required_label' => nil, 'categories' => [], 'check_ids' => [],
                                                  'credits_from_check' => false }] }]

    assert_raises(CurriculumReader::Error) { reader(StubClient.new(answer)).read_requirements(text: 't', image_path: nil) }
  end

  test 'エラーのメッセージには、答えの中身も画像の場所も入れない' do
    secret = 'zzz-secret-in-the-answer'
    error = assert_raises(CurriculumReader::Error) do
      reader(StubClient.new('courses' => [], 'extra' => secret))
        .read_courses(text: 't', image_path: '/x/p1.png', categories: [])
    end

    assert_not_includes error.message, secret
    assert_not_includes error.message, '/x/p1.png'
  end

  # --- 窓口の形

  test '窓口は HTTP を知らない(net/http を読み込むのはプロバイダだけ)' do
    source = Rails.root.join('app/services/curriculum_reader.rb').read

    assert_no_match(%r{Net::HTTP|net/http|generativelanguage}, source)
  end

  test 'プロバイダは便覧を知らない(区分・規則・プロンプトを参照しない)' do
    source = Rails.root.join('app/services/curriculum_reader/gemini.rb').read

    assert_no_match(/Prompts|Schemas|Catalogue|categories|credit_sum/, source)
  end

  test '既定のプロバイダは Gemini' do
    assert_equal CurriculumReader::Gemini, CurriculumReader::PROVIDER
  end

  # --- スキーマが便覧の検査とずれていないこと

  test '表示のスキーマの欄は、Catalogue が許す欄と同じ' do
    display = CurriculumReader::Schemas.requirements.dig(:properties, :display)
    group = display.dig(:properties, :groups, :items)
    row = group.dig(:properties, :rows, :items)
    subtotal = display.dig(:properties, :subtotals, :items)
    catalogue = GraduationAssessment::Catalogue

    assert_equal catalogue::DISPLAY_KEYS.sort, display[:properties].keys.map(&:to_s).sort
    assert_equal catalogue::DISPLAY_GROUP_KEYS.sort, group[:properties].keys.map(&:to_s).sort
    assert_equal catalogue::DISPLAY_ROW_KEYS.sort, row[:properties].keys.map(&:to_s).sort
    assert_equal catalogue::DISPLAY_SUBTOTAL_KEYS.sort, subtotal[:properties].keys.map(&:to_s).sort
  end

  test '規則の型は、コードが解釈する型と同じ' do
    rule_types = CurriculumReader::Schemas.requirements.dig(:properties, :rules, :items, :properties, :type, :enum)
    expected = GraduationAssessment::Rules::TOP_LEVEL + GraduationAssessment::Rules::ADJUSTMENTS.keys

    assert_equal expected.sort, rule_types.sort
  end

  test '型ごとの必須の欄の表は、規則の型(入れ子の all_of を含む)を漏れなく覆う' do
    expected = GraduationAssessment::Rules::TOP_LEVEL + GraduationAssessment::Rules::ADJUSTMENTS.keys

    assert_equal (expected + ['all_of']).sort, CurriculumReader::Schemas::RULE_REQUIRED.keys.sort
  end
end

