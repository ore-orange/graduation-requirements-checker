# frozen_string_literal: true

require 'test_helper'

class CurriculumTest < ActiveSupport::TestCase
  FILE = Rails.root.join('config/curricula/intelligent_informatics/2024.json')

  test '公開済みは同じ slug と年度で2つ作れない' do
    Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
    end
  end

  test '下書きは同じ slug と年度で何件でも作れる' do
    2.times { Curriculum.create!(slug: 'x', admission_year: 2024, document: {}) }
    assert_equal 2, Curriculum.where(slug: 'x').count
  end

  test '公開済みがあっても、同じ slug と年度の下書きを作れる' do
    Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
    draft = Curriculum.create!(slug: 'x', admission_year: 2024, document: {})
    assert_not_predicate draft, :published?
    assert_equal [draft], Curriculum.where(slug: 'x').where(published_at: nil).to_a
  end

  test 'published は公開済みだけを返す' do
    published = Curriculum.create!(slug: 'x', admission_year: 2024, published_at: Time.current)
    Curriculum.create!(slug: 'x', admission_year: 2024)
    assert_equal [published], Curriculum.published.where(slug: 'x').to_a
  end

  test 'document の既定は空のハッシュ' do
    assert_equal({}, Curriculum.create!(slug: 'x', admission_year: 2024).document)
  end

  test 'slug と入学年度は必須' do
    assert_not Curriculum.new(admission_year: 2024).valid?
    assert_not Curriculum.new(slug: 'x').valid?
  end

  test 'seed_from_file は便覧ファイルを公開済みとして入れる' do
    curriculum = Curriculum.seed_from_file(FILE)
    assert_equal 'intelligent_informatics', curriculum.slug
    assert_equal 2024, curriculum.admission_year
    assert_predicate curriculum, :published?
    assert_predicate curriculum, :persisted?
    assert_equal 484, curriculum.document.fetch('courses').size
    assert_equal '2024年度入学 琉球大学工学部工学科 知能情報コース', curriculum.title
  end

  test 'seed_from_file は何度流しても同じ行を更新し、増やさない' do
    first = Curriculum.seed_from_file(FILE)
    count = Curriculum.where(slug: 'intelligent_informatics', admission_year: 2024).count
    second = Curriculum.seed_from_file(FILE)
    assert_equal first.id, second.id
    assert_equal count, Curriculum.where(slug: 'intelligent_informatics', admission_year: 2024).count
    assert_equal 1, Curriculum.published.where(slug: 'intelligent_informatics', admission_year: 2024).count
  end

  test 'seed_from_file は同じ年度の下書きに触れない' do
    draft = Curriculum.create!(slug: 'intelligent_informatics', admission_year: 2024, document: { 'draft' => true })
    Curriculum.seed_from_file(FILE)
    assert_equal({ 'draft' => true }, draft.reload.document)
    assert_not_predicate draft, :published?
  end

  test 'catalogue は便覧の規則を返す' do
    catalogue = Curriculum.seed_from_file(FILE).catalogue
    assert_instance_of GraduationAssessment::Catalogue, catalogue
    assert_includes catalogue.conditions.map(&:id), 'common_total'
  end

  test '壊れた便覧の catalogue は握りつぶさず例外にする' do
    document = JSON.parse(FILE.read)
    document['courses'] << document['courses'].first
    curriculum = Curriculum.create!(slug: 'broken', admission_year: 2024, document: document,
                                    published_at: Time.current)
    assert_raises(ArgumentError) { curriculum.catalogue }
  end
end

