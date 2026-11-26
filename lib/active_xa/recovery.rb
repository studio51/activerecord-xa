# frozen_string_literal: true

module ActiveXA
  # Resolves branches left PREPARED by a crash or a failed commit:
  #
  # * decision logged  -> XA COMMIT
  # * no decision      -> XA ROLLBACK (presumed abort)
  #
  # Only XIDs older than the grace period are touched, so recovery never
  # races a coordinator that is still between PREPARE and COMMIT. Needs the
  # XA_RECOVER_ADMIN privilege on each database.
  #
  # XA RECOVER lists every prepared XID on the *server*, not just the
  # database the connection points at, so participants sharing a server see
  # each other's branches. XIDs are de-duplicated; any connection to the
  # right server can resolve a detached branch.
  class Recovery
    Report = Struct.new(:committed, :rolled_back, :skipped, :pruned, :errors) do
      def initialize = super([], [], [], [], [])
    end

    def initialize(record_classes, log:, grace:)
      @pools = record_classes.map(&:connection_pool).uniq
      @log = log
      @grace = grace
    end

    def run
      report = Report.new
      handled = {}

      @pools.each do |pool|
        with_connection(pool) do |connection|
          prepared_xids(connection).each do |xid|
            next if handled[xid.to_s]

            handled[xid.to_s] = true
            resolve(connection, xid, report)
          end
        end
      end

      outstanding = (report.skipped + report.errors.map(&:first)).map(&:gtrid)
      prune_log(outstanding.uniq, report)
      report
    end

    private
      def resolve(connection, xid, report)
        unless old_enough?(xid.gtrid)
          report.skipped << xid
          return
        end

        if @log.committed?(xid.gtrid)
          connection.execute("XA COMMIT #{xid.to_sql(connection)}")
          report.committed << xid
        else
          connection.execute("XA ROLLBACK #{xid.to_sql(connection)}")
          report.rolled_back << xid
        end
      rescue => e
        report.errors << [xid, e]
      end

      # A decision with no branch still outstanding is finished: every branch
      # has committed (possibly just now), so the row can go.
      def prune_log(outstanding_gtrids, report)
        @log.entries.each do |gtrid|
          next if outstanding_gtrids.include?(gtrid)
          next unless old_enough?(gtrid)

          @log.complete!(gtrid)
          report.pruned << gtrid
        end
      rescue => e
        report.errors << [:prune, e]
      end

      def prepared_xids(connection)
        connection.select_rows("XA RECOVER").filter_map do |format_id, gtrid_length, bqual_length, data|
          next unless Integer(format_id) == Xid::FORMAT_ID

          # The lengths count bytes, and data is not always single-byte.
          gl = Integer(gtrid_length)
          Xid.new(data.byteslice(0, gl), data.byteslice(gl, Integer(bqual_length)))
        end
      end

      def old_enough?(gtrid)
        created = Xid.created_at(gtrid)
        created.nil? || Time.now - created >= @grace
      end

      def with_connection(pool)
        connection = pool.checkout
        yield connection
      ensure
        pool.checkin(connection) if connection
      end
  end
end
