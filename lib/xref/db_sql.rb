# frozen_string_literal: true

module Xref
  # SQL that lives IN THE DATABASE rather than in the tree: the bodies of
  # rewrite rules, of trigger functions and of stored functions.
  #
  # Needed because without it the index lied in the dangerous direction. An
  # accumulating rule `ON INSERT … DO INSTEAD UPDATE … SET x = x + new.x` READS
  # the column it increments — while from the code that column looked unread,
  # and the conclusion "written but nobody reads it" would have been wrong.
  # There are 59 such rules in production.
  #
  # Parsed by the same parser as the files: `CodeScanner` with a `.sql`
  # extension yields tables, columns, write targets and value lineage. There is
  # no second parser of our own here, and there must not be.
  module DbSql
    # A plpgsql body is not parsed by the database's parser: it only knows the
    # outer `CREATE FUNCTION`. For such functions a SEPARATE, weaker class is
    # recorded — "not parsed" — instead of silence.
    PARSEABLE_LANGUAGES = %w[sql internal].freeze

    class << self
      # => { rules:, triggers:, routines:, refs:, unparsed: }
      def collect(source, conn: Store.conn)
        snapshot = conn.select_value(<<~SQL.squish)
          select snapshot_id from v_current where source = #{conn.quote(source.to_s)}
        SQL
        return nil if snapshot.nil?

        known = Store.known_names
        stats = { rules: 0, triggers: 0, routines: 0, refs: 0, unparsed: 0 }
        rows = []

        each_object(conn, snapshot) do |object_kind, object, body, language|
          stats[:"#{object_kind}s"] += 1
          if language && !PARSEABLE_LANGUAGES.include?(language)
            stats[:unparsed] += 1
            rows << [snapshot, object, object_kind, 'db_unparsed', language, '',
                     { reason: 'тело на этом языке парсер постгреса не разбирает' }.to_json]
            next
          end

          refs = CodeScanner.new("#{object_kind}.sql", body.to_s, known: known).scan
          refs.each do |ref|
            next unless %w[pg_table pg_column pg_column_write col_lineage sql_blind].include?(ref.kind)

            stats[:refs] += 1
            rows << [snapshot, object, object_kind, ref.kind, ref.token[0, 500], ref.owner,
                     ref.detail&.to_json]
          end
        end

        conn.execute("delete from db_refs where snapshot_id = #{conn.quote(snapshot)}")
        Store.insert_rows('db_refs', %w[snapshot_id object object_kind kind token owner detail],
                          rows.uniq { |row| [row[1], row[3], row[4], row[5]] })
        stats
      end

      private

      def each_object(conn, snapshot)
        conn.select_all(<<~SQL.squish).each do |row|
          select table_name || '.' || rule_name as object, definition from db_rules
          where snapshot_id = #{conn.quote(snapshot)} order by 1
        SQL
          yield 'rule', row['object'], row['definition'], 'sql'
        end

        # A trigger holds no SQL itself — it calls a function. That function is
        # what gets parsed, while the "table -> function" link stays in
        # `db_triggers`.
        conn.select_all(<<~SQL.squish).each do |row|
          select t.table_name || '.' || t.trigger_name as object, p.body, p.language
          from db_triggers t
          left join db_routines p
            on p.snapshot_id = t.snapshot_id and p.name = t.function_name
          where t.snapshot_id = #{conn.quote(snapshot)} order by 1
        SQL
          next if row['body'].blank?

          yield 'trigger', row['object'], row['body'], row['language']
        end

        conn.select_all(<<~SQL.squish).each do |row|
          select identity as object, body, language from db_routines
          where snapshot_id = #{conn.quote(snapshot)} order by 1
        SQL
          next if row['body'].blank?

          yield 'routine', row['object'], row['body'], row['language']
        end
      end
    end
  end
end
