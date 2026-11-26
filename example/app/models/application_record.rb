# frozen_string_literal: true

# Models in the shop database.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  connects_to database: { writing: :primary }
end
