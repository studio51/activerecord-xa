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
    MAX_PART_BYTES = 64 # MySQL's limit for gtrid and for bqual, in bytes

    attr_reader :gtrid, :bqual

    def self.generate_gtrid
      "#{PREFIX}-#{(Time.now.to_f * 1000).to_i}-#{SecureRandom.hex(12)}"
    end

    # The index keeps the qualifier unique within its gtrid; the database
    # name is there for whoever reads XA RECOVER. A long multi-byte name is
    # cut on a byte boundary, so a split trailing character is dropped.
    def self.bqual(index, name)
      "#{index}-#{name}".byteslice(0, MAX_PART_BYTES).scrub("")
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
