# frozen_string_literal: true

require "securerandom"

module ActiveRecord::XA

  # An XA transaction identifier: MySQL names a branch by (gtrid, bqual, formatID).
  # The gtrid is shared by every branch of one global transaction, and the bqual names the branch.
  # The formatID marks the XID as ActiveRecord::XA's in XA RECOVER output.
  # The gtrid also carries the namespace of the decision log that decides it, so recovery can tell its own transactions from another installation's, and its creation time, for the grace period.
  #
  #   axa-<namespace>-<start time in ms>-<random>
  #
  class Xid

    # --- Format ---

    FORMAT_ID      = 0x41584131 # "AXA1", marks ActiveRecord::XA's XIDs in XA RECOVER
    PREFIX         = "axa".freeze # first segment of every gtrid
    MAX_PART_BYTES = 64 # MySQL's limit for gtrid and for bqual, in bytes

    # The shape of a gtrid ActiveRecord::XA generated.
    #
    GTRID = /\A#{ PREFIX }-(?<namespace>\h{8})-(?<millis>\d{1,15})-\h+\z/

    attr_reader :gtrid # global transaction id, shared by every branch
    attr_reader :bqual # branch qualifier, unique within the gtrid

    class << self

      # Generates a gtrid for a new global transaction.
      #
      # @param namespace [String] the decision log's namespace, eight hex digits
      # @return [String] the gtrid, at most 47 bytes
      def generate_gtrid(namespace)
        "#{ PREFIX }-#{ namespace }-#{ (Time.now.to_f * 1000).to_i }-#{ SecureRandom.hex(12) }"
      end

      # Builds the qualifier for one branch.
      # The index keeps it unique within its gtrid, and the database name is there for whoever reads XA RECOVER.
      # A long multi-byte name is cut on a byte boundary, so a split trailing character is dropped.
      #
      # @param index [Integer] the participant's position in the transaction
      # @param name [String] the participant's database config name
      # @return [String] the qualifier, at most 64 bytes of valid UTF-8
      def bqual(index, name)
        "#{ index }-#{ name }".byteslice(0, MAX_PART_BYTES).scrub("")
      end

      # Reads the namespace out of a gtrid.
      #
      # @param gtrid [String] the gtrid
      # @return [String, nil] the namespace, or nil if ActiveRecord::XA did not make the gtrid
      def namespace(gtrid)
        parse(gtrid)&.[](:namespace)
      end

      # Reads the start time out of a gtrid.
      #
      # @param gtrid [String] the gtrid
      # @return [Time, nil] when the transaction started, or nil if ActiveRecord::XA did not make the gtrid
      def created_at(gtrid)
        millis = parse(gtrid)&.[](:millis)

        Time.at(millis.to_i / 1000.0) if millis
      end

      private

        # Matches a gtrid against the format ActiveRecord::XA generates.
        #
        # @param gtrid [String] the gtrid
        # @return [MatchData, nil] the match, or nil
        def parse(gtrid)
          GTRID.match(gtrid) if gtrid.valid_encoding?
        end
    end

    # Creates an XID.
    #
    # @param gtrid [String] the global transaction id
    # @param bqual [String] the branch qualifier
    # @return [Xid] the new XID
    def initialize(gtrid, bqual)
      @gtrid = gtrid
      @bqual = bqual
    end

    # Renders the XID for an XA statement.
    #
    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] the connection that quotes the parts
    # @return [String] the quoted gtrid, bqual and formatID, comma separated
    def to_sql(connection)
      "#{ connection.quote(gtrid) },#{ connection.quote(bqual) },#{ FORMAT_ID }"
    end

    # Renders the XID for logs and error messages.
    #
    # @return [String] gtrid/bqual
    def to_s
      "#{ gtrid }/#{ bqual }"
    end
  end
end
