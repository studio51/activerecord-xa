# frozen_string_literal: true

require "securerandom"

module ActiveXA
  # MySQL identifies an XA branch by (gtrid, bqual, formatID).
  # gtrid is shared by every branch of one global transaction; bqual names
  # the branch. The formatID marks the XID as ours in XA RECOVER output, and
  # the gtrid embeds its creation time so recovery can apply a grace period.
  class Xid
    FORMAT_ID = 0x41584131 # "AXA1"
    PREFIX = "axa"

    attr_reader :gtrid, :bqual

    def self.generate_gtrid
      "#{PREFIX}-#{(Time.now.to_f * 1000).to_i}-#{SecureRandom.hex(12)}"
    end

    def self.created_at(gtrid)
      _prefix, millis, _rand = gtrid.split("-", 3)
      Time.at(Integer(millis, 10) / 1000.0)
    rescue ArgumentError, TypeError
      nil
    end

    def initialize(gtrid, bqual)
      @gtrid = gtrid
      @bqual = bqual
    end

    def to_sql(connection)
      "#{connection.quote(gtrid)},#{connection.quote(bqual)},#{FORMAT_ID}"
    end

    def to_s
      "#{gtrid}/#{bqual}"
    end
  end
end
