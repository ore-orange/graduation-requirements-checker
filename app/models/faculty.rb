# frozen_string_literal: true

class Faculty < ApplicationRecord
  has_many :departments, dependent: :restrict_with_error

  validates :name, presence: true
end

