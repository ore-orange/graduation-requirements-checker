# frozen_string_literal: true

class StudentProgramAssignment < ApplicationRecord
  belongs_to :student
  belongs_to :program

  validates :status, presence: true
  validate :chronological_dates

  private

  def chronological_dates
    return if ended_at.nil?
    return if assigned_at.present? && ended_at >= assigned_at

    errors.add(:ended_at, 'must be on or after assigned_at')
  end
end

