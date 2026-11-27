# frozen_string_literal: true

# Models in the ledger database, a separate MySQL database.
class LedgerRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :ledger }
end
