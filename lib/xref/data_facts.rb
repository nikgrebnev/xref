# frozen_string_literal: true

module Xref
  # Facts from the LIVE DATA: column fill rates and index scans.
  #
  # Why a separate level. To the question "which fields are redundant" the code
  # and the schema answer only half: "nobody reads it" and "there is nothing in
  # it" are different statements, and the answer "it can be dropped" needs both.
  # Without this collector the numbers had to be obtained with a throwaway
  # script, and three times in a row the same traps showed up in it — they are
  # closed here now:
  #
  # 1. **The default.** With `default 1` a column nobody ever touched is, by the
  #    "non-zero" count, filled for every single row. What matters is a
  #    different number: how many rows DIFFER from the default. For two
  #    notification columns that was 208,356 and 226,366 people — they switched
  #    the notification off, and nothing in the code reads the column.
  # 2. **The type.** `boolean <> 0` is a database error rather than "zero rows":
  #    the run died on the first such column. Text is compared against an empty
  #    string, a date only against NULL.
  # 3. **Recency.** A total count does not tell a dead mechanism from a live
  #    one: one column had 141,006 filled rows in total and 1 in the recent
  #    cohort. A second measure is needed — over those who arrived lately.
  #
  # The pass is EXHAUSTIVE, with no sampling: shares computed from a sample once
  # already overstated a problem by a factor of seven hundred.
  module DataFacts
    # The column the "recent cohort" is counted by comes from the configuration
    # (`idioms.recency_columns`): the first one found on the table is taken, and
    # guessing by type is not possible — a table may hold five dates. The list
    # is a habit of a tree, not a property of the engine (III.4).
    def self.recent_candidates
      Array(Xref.idioms[:recency_columns]).map(&:to_s)
    end

    RECENT_WINDOW = "interval '1 year'"
    STATEMENT_TIMEOUT = "'900s'"

    class << self
      # => { tables: n, columns: n, skipped: [...] }
      def collect(source, tables:, conn: Store.conn)
        stats = { tables: 0, columns: 0, skipped: [] }
        rows = []

        tables.each do |table|
          columns = columns_of(source, table, conn: conn)
          if columns.empty?
            stats[:skipped] << "#{table}: нет в снимке схемы источника #{source}"
            next
          end

          measured = measure(source, table, columns)
          if measured.nil?
            stats[:skipped] << "#{table}: запрос к источнику не удался#{@last_error ? " — #{@last_error}" : ''}"
            @last_error = nil
            next
          end

          stats[:tables] += 1
          stats[:columns] += measured.size
          rows.concat(measured)
        end

        Store.write_column_fill(source, rows)
        stats
      end

      # Index scans: for the whole database at once — this is the catalogue, and
      # it is cheap.
      def index_usage(source)
        out = SchemaSource.new(source.to_s).run(<<~SQL)
          \\set ON_ERROR_STOP on
          select s.relname, s.indexrelname, s.idx_scan, pg_relation_size(s.indexrelid),
                 i.indisunique, i.indisprimary,
                 coalesce((select stats_reset from pg_stat_database where datname = current_database()),
                          pg_postmaster_start_time())
          from pg_stat_user_indexes s
          join pg_index i on i.indexrelid = s.indexrelid
        SQL
        parsed = out.to_s.lines.filter_map do |line|
          parts = line.strip.split('|')
          next if parts.size < 7

          { table_name: parts[0], index_name: parts[1], scans: parts[2].to_i,
            size_bytes: parts[3].to_i, is_unique: parts[4] == 't', is_primary: parts[5] == 't',
            since: parts[6] }
        end
        Store.write_index_usage(source, parsed)
        parsed.size
      end

      private

      def columns_of(source, table, conn:)
        conn.select_rows(<<~SQL.squish)
          select c.column_name, c.data_type, coalesce(c.default_expr, '')
          from db_columns c join v_current v on v.snapshot_id = c.snapshot_id
          where v.source = #{conn.quote(source.to_s)} and c.table_name = #{conn.quote(table.to_s)}
          order by c.ordinal
        SQL
      end

      def measure(source, table, columns)
        recent = columns.map(&:first).find { |name| recent_candidates.include?(name) }
        recent_cond = recent && "#{quote_ident(recent)} > extract(epoch from now() - #{RECENT_WINDOW})"
        # A date column is sometimes a real date rather than a number: the
        # comparison is chosen by type, otherwise the whole query fails and the
        # table is left without a measurement.
        recent_type = columns.find { |name, _| name == recent }&.at(1).to_s
        if recent && (recent_type.start_with?('timestamp') || recent_type == 'date')
          recent_cond = "#{quote_ident(recent)} > now() - #{RECENT_WINDOW}"
        end

        parts = ['count(*)']
        parts << (recent_cond ? "count(*) filter (where #{recent_cond})" : 'null::bigint')
        columns.each do |name, type, default|
          filled = filled_condition(name, type)
          parts << "count(*) filter (where #{filled})"
          parts << (default.present? ? "count(*) filter (where #{off_default(name, default)})" : 'null::bigint')
          parts << (recent_cond ? "count(*) filter (where #{recent_cond} and #{filled})" : 'null::bigint')
        end

        sql = "\\set ON_ERROR_STOP on\nset statement_timeout = #{STATEMENT_TIMEOUT};\n" \
              "select #{parts.join(', ')} from #{quote_ident(table)}"
        # A failure on ONE table must not kill the run over the others: the
        # caller gets nil, the table goes into "skipped" and is NAMED there.
        # Silence is not allowed (a table with no measurement reads as a table
        # full of zeroes), but neither is losing twenty-three measurements
        # because of the twenty-fourth.
        values = begin
          SchemaSource.new(source.to_s).run(sql).to_s.lines
                      .reject { |line| line.strip.empty? }.last&.strip&.split('|', -1)
        rescue Xref::Error => e
          @last_error = e.message.to_s.lines.first.to_s.strip[0, 140]
          nil
        end
        return nil if values.nil? || values.size != 2 + (columns.size * 3)

        total = values[0].to_i
        total_recent = values[1].presence&.to_i
        columns.each_with_index.map do |(name, _type, _default), index|
          base = 2 + (index * 3)
          { table_name: table.to_s, column_name: name, rows_total: total, rows_recent: total_recent,
            filled: values[base].to_i, off_default: values[base + 1].presence&.to_i,
            filled_recent: values[base + 2].presence&.to_i, recent_by: recent }
        end
      end

      # What "the column holds a value" means depends on the type. This is not
      # pedantry: `boolean <> 0` kills the whole query and the table is left
      # without a measurement. A comparison against zero is for NUMBERS ONLY,
      # and the list is closed. Previously everything unknown fell into `<> 0`,
      # and the first `interval` column brought down an ENTIRE run — 24 tables
      # left unmeasured because of one column. The rule is inverted now: an
      # unknown type gets the weakest but always legal condition, `is not null`.
      NUMERIC_TYPES = ['smallint', 'integer', 'bigint', 'numeric', 'decimal',
                       'real', 'double precision', 'money'].freeze

      def filled_condition(name, type)
        column = quote_ident(name)
        kind = type.to_s
        case kind
        when 'boolean' then column
        when 'text', /\Acharacter/ then "#{column} is not null and #{column} <> ''"
        when *NUMERIC_TYPES then "#{column} is not null and #{column} <> 0"
        else "#{column} is not null"
        end
      end

      # `(1)::smallint`, `'f'::boolean`, `nextval(...)` — a default arrives as
      # an expression. It is compared as it is: the database understands it, and
      # there is no reason for us to parse it. `is distinct from` matters — with
      # NULL a plain `<>` says nothing.
      #
      # NULL is excluded from the count: the question is "how many people set
      # something OTHER than what is set for them", and an empty value does not
      # answer it. Without that, a column with a default and a million NULLs had
      # more "off default" than "filled", and the number read as nonsense.
      def off_default(name, default)
        column = quote_ident(name)
        "#{column} is not null and #{column} is distinct from (#{default})"
      end

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end
    end
  end
end
