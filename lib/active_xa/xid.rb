# frozen_string_literal: true

require "securerandom"

module ActiveXA
  # MySQL identifies an XA branch by (gtrid, bqual, formatID).
  # gtrid is shared by every branch of one global transaction; bqual names
  # the branch. The formatID marks the XID as ActiveXA's in XA RECOVER
  # output. The gtrid carries the namespace of the decision log that decides
  # it, so recovery can tell its own transactions from another
  # installation's, and its creation time, for the grace period:
  #
  #   axa-<namespace>-<start time in ms>-<random>
  #
  class Xid
    FORMAT_ID = 0x41584131 # "AXA1"
    PREFIX = "axa"
    GTRID = /\A#{ PREFIX }-(?<namespace>\h{8})-(?<millis>\d{1,15})-\h+\z/
    MAX_PART_BYTES = 64 # MySQL's limit for gtrid and for bqual, in bytes

    attr_reader :gtrid, :bqual

    def self.generate_gtrid(namespace)
      "#{ PREFIX }-#{ namespace }-#{ (Time.now.to_f * 1000).to_i }-#{ SecureRandom.hex(12) }"
    end

    # The namespace a gtrid belongs to, or nil if ActiveXA did not make it.
    #
    def self.namespace(gtrid)
      parse(gtrid)&.[](:namespace)
    end

    # The index keeps the qualifier unique within its gtrid; the database
    # name is there for whoever reads XA RECOVER. A long multi-byte name is
    # cut on a byte boundary, so a split trailing character is dropped.
    #
    def self.bqual(index, name)
      "#{ index }-#{ name }".byteslice(0, MAX_PART_BYTES).scrub("")
    end

    def self.created_at(gtrid)
      millis = parse(gtrid)&.[](:millis)

      Time.at(millis.to_i / 1000.0) if millis
    end

    def self.parse(gtrid)
      GTRID.match(gtrid) if gtrid.valid_encoding?
    end
    private_class_method :parse

    def initialize(gtrid, bqual)
      @gtrid = gtrid
      @bqual = bqual
    end

    def to_sql(connection)
      "#{ connection.quote(gtrid) },#{ connection.quote(bqual) },#{ FORMAT_ID }"
    end

    def to_s
      "#{ gtrid }/#{ bqual }"
    end
  end
end
