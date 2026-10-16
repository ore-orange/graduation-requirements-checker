# frozen_string_literal: true

module DemoHelper
  CATEGORY_LABELS = {
    'health' => '健康運動', 'humanities' => '人文系', 'social' => '社会系', 'natural' => '自然系',
    'integrated' => '総合', 'career' => 'キャリア', 'regional' => '地域', 'japanese' => '日本語表現',
    'english' => '英語', 'foreign_language' => 'その他外国語', 'basic' => '専門基礎',
    'required_information' => '専門必修・情報', 'required_comprehensive' => '専門必修・総合',
    'required_research' => '専門必修・研究', 'required_math' => '専門必修・数学',
    'required_core' => '専門必修・基幹', 'elective_math' => '専門選択・数学', 'advanced' => '専門選択・発展',
    'related' => '専門選択・関連', 'fusion' => '工学融合', 'free' => '自由', 'excluded' => '算入対象外'
  }.freeze

  def assessment_status_label(status)
    { satisfied: '充足', unmet: '不足あり', needs_review: '要確認' }.fetch(status)
  end

  def assessment_status_class(status)
    { satisfied: 'status-satisfied', unmet: 'status-unmet', needs_review: 'status-review' }.fetch(status)
  end

  def credit_label(credits)
    credits.nil? ? '未確認' : "#{number_with_precision(credits, precision: 2, strip_insignificant_zeros: true)} 単位"
  end

  def category_label(category)
    CATEGORY_LABELS.fetch(category, category)
  end

  def enrollment_status_label(status)
    { 'completed' => '修得済み', 'registered' => '履修登録済み', 'in_progress' => '履修中',
      'failed' => '未修得', 'unknown' => '状態未確認' }.fetch(status, '状態未確認')
  end

  def catalogue_availability(course, unavailable_keys:, persisted_keys:)
    return '追加済み・修得済み・履修中' if unavailable_keys.include?(course['key'])
    return '選択対象外' unless course['selectable'] == true
    return '初期データ未登録（bin/rails db:seed を実行）' unless persisted_keys.include?(course['key'])

    nil
  end

  def source_url(source)
    url = source['url'].to_s
    url if url.start_with?('https://', 'http://')
  end
end

