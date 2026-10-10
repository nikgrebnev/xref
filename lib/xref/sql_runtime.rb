# frozen_string_literal: true

require 'open3'
require 'digest'

module Xref
  # Queries that actually RAN — from production logs.
  #
  # This answers the largest blind spot of a static parse: a table name
  # assembled by interpolation (`tag_cache#{i}`, `sessions_live#{n}`,
  # `s_forum#{id}_view2`). Statically only "what the name was assembled from" is
  # known; the log knows WHAT came out of it — `tag_cache4`, `sessions_live3`.
  #
  # Two things here are deliberate and both matter.
  #
  # **Values never leave the node.** The parse runs ON THE NODE, and the first
  # thing the script does is replace literals: strings with `'x'`, numbers with
  # `1`. What travels back is a query skeleton and a counter. No address, no
  # key, no body of an email is in the index, and none can be.
  #
  # **Numbers inside NAMES are left alone.** `events_log2`, `sessions_live3`,
  # `tag_cache4` are the table names the whole exercise is about; replacing
  # "any number" would destroy exactly them.
  module SqlRuntime
    CONNECT_TIMEOUT = 25
    SSH_TIMEOUT = 1800
    # The skeleton is cut, otherwise kilometre-long queries travel into the
    # index. But cutting it SHORT is not allowed: a production field list is 64
    # names and nine hundred characters, and with a 400-character cut the
    # columns from the tail looked "untouched in production".
    MAX_SKELETON = 1500

    # `grep -oiE` pulls the query itself out of the log line; then comes
    # normalisation. `cut` keeps the skeleton short: the report needs names, not
    # the whole text.
    SCRIPT = <<~SH
      set -u
      for f in $FILES; do
        [ -f "$f" ] || continue
        sed -e 's/\\x1b\\[[0-9;]*m//g' "$f"
      done \\
      | grep -oiE '(SELECT|INSERT INTO|UPDATE|DELETE FROM|WITH) .*$' \\
      | sed -e "s/E'[^']*'/'x'/g" -e "s/'[^']*'/'x'/g" \\
            -e 's/\\([^A-Za-z0-9_$]\\)[0-9][0-9.]*/\\1 1/g' \\
            -e "s/'x'\\( *, *'x'\\)\\+/'x'/g" \\
            -e 's/\\( 1\\)\\( *, *1\\)\\+/ 1/g' \\
            -e 's/[[:space:]]\\+/ /g' \\
      | cut -c1-#{MAX_SKELETON} \\
      | sort | uniq -c | sort -rn \\
      | awk '{n=$1; $1=""; sub(/^ /,""); if (length($0) > 12) print n "|" $0}'
    SH

    class << self
      # => [{ host:, day:, skeleton:, hits: }, …]
      def collect(host, glob, day: Date.today)
        files = glob.to_s.gsub('DATE', day.strftime('%Y-%m-%d'))
        out, err, status = Open3.capture3(
          'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
          host.to_s, "FILES='#{files}' sh -s", stdin_data: SCRIPT
        )
        raise Error, "#{host}: ssh вернул #{status.exitstatus}: #{err.strip.lines.last(2).join(' ')}" unless status.success?

        parse(out, host: host, day: day)
      end

      # TRUNCATION MUST NOT INVENT NAMES. The skeleton is cut by length, and
      # cutting at a character puts the cut in the middle of a name: `… from
      # big_users` became `… from big_`, and the parse recorded a table `big_`
      # that does not exist. Downstream that reads as "the code touches a table
      # that is missing" — a false finding in the most dangerous direction. So
      # the cut goes at the last whitespace: the tail is lost anyway, but a
      # whole name does not turn into a stump.
      def trim_tail(skeleton, limit = MAX_SKELETON)
        text = skeleton.to_s
        return text if text.length < limit

        cut = text.rindex(/\s/)
        cut ? text[0...cut].rstrip : text
      end

      def parse(out, host:, day:)
        # The skeleton arrives FROM THE NODE: normalisation strips the values,
        # but a comment inside the query and a broken byte in it remain, and
        # `split` does not forgive those.
        Xref.utf8(out).lines.filter_map do |line|
          hits, skeleton = line.strip.split('|', 2)
          next if skeleton.blank? || hits.to_i.zero?

          { host: host.to_s, day: day, skeleton: trim_tail(skeleton.strip[0, MAX_SKELETON]),
            hits: hits.to_i }
        end
      end

      # Parsing the skeleton happens here, with the same parser as the files.
      # The skeleton already carries no values, so it parses more often than
      # code does: there are neither holes nor concatenations in it.
      #
      # Columns are split into two classes, and the difference is decisive. In
      # production a query selects the WHOLE field list (`select <64 names> from
      # legacy_users`) — "named in the selection" does not mean anyone needs the
      # value. A column in a CONDITION or in an ordering does work: rows are
      # filtered by it.
      def analyze(rows, known: Store.known_names)
        rows.map do |row|
          refs = CodeScanner.new('runtime.sql', row[:skeleton], known: known).scan
          by = ->(kind) { refs.select { |ref| ref.kind == kind }.map(&:token).uniq }
          parsed = refs.none? { |ref| %w[sql_blind sql_piece].include?(ref.kind) }
          row.merge(tables: by.call('pg_table'), columns: by.call('pg_column'),
                    filters: by.call('pg_column_filter'), writes: by.call('pg_column_write'),
                    parsed: parsed)
        end
      end
    end
  end
end
