# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'json'

module Xref
  # Taking the schema of one source.
  #
  # pg_catalog is asked rather than information_schema: relkind is needed (an
  # ordinary table / a partition / a view / a materialised view), and one and
  # the same query has to work identically on 13.1, 13.7 and 18.3.
  #
  # The transport to production databases is ssh + `docker exec -i psql`,
  # because a tunnel to them does not come up: the database container publishes
  # a different port outwards, and there is no route to 5432 itself from a
  # developer machine (verified 2026-08-21).
  class SchemaSource
    CONNECT_TIMEOUT = 20
    THRIFT_TIMEOUT = 10

    INTROSPECT_SQL = <<~SQL
      select json_build_object(
        'server_version', current_setting('server_version'),
        'database', current_database(),
        'tables', coalesce((select json_agg(t) from (
            select c.relname as name,
                   c.relkind::text as kind,
                   c.reltuples::bigint as est_rows
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public'
              and c.relkind in ('r','p','v','m','f')
            order by c.relname) t), '[]'::json),
        'columns', coalesce((select json_agg(c) from (
            select cl.relname as table_name,
                   a.attname as column_name,
                   a.attnum as ordinal,
                   format_type(a.atttypid, a.atttypmod) as data_type,
                   a.attnotnull as not_null,
                   pg_get_expr(d.adbin, d.adrelid) as default_expr
            from pg_attribute a
            join pg_class cl on cl.oid = a.attrelid
            join pg_namespace n on n.oid = cl.relnamespace
            left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
            where n.nspname = 'public'
              and a.attnum > 0
              and not a.attisdropped
              and cl.relkind in ('r','p','v','m','f')
            order by cl.relname, a.attnum) c), '[]'::json),
        'indexes', coalesce((select json_agg(i) from (
            select t.relname as table_name,
                   ir.relname as index_name,
                   ix.indisunique as is_unique,
                   ix.indisprimary as is_primary,
                   pg_get_indexdef(ir.oid) as definition
            from pg_index ix
            join pg_class ir on ir.oid = ix.indexrelid
            join pg_class t on t.oid = ix.indrelid
            join pg_namespace n on n.oid = t.relnamespace
            where n.nspname = 'public'
            order by t.relname, ir.relname) i), '[]'::json),
        -- Rewrite rules. `_RETURN` is the body of a view and is not taken: the
        -- view is already among the relations. Everything else is a genuine
        -- rewrite, and it CHANGES the meaning of a query: an insert may turn
        -- out to be an update.
        'rules', coalesce((select json_agg(r) from (
            select c.relname as table_name, rw.rulename as rule_name,
                   case rw.ev_type when '1' then 'select' when '2' then 'update'
                                   when '3' then 'insert' when '4' then 'delete'
                                   else rw.ev_type::text end as event,
                   rw.is_instead, pg_get_ruledef(rw.oid, true) as definition
            from pg_rewrite rw
            join pg_class c on c.oid = rw.ev_class
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and rw.rulename <> '_RETURN'
            order by c.relname, rw.rulename) r), '[]'::json),
        'triggers', coalesce((select json_agg(t) from (
            select c.relname as table_name, tg.tgname as trigger_name,
                   tg.tgfoid::regproc::text as function_name,
                   pg_get_triggerdef(tg.oid, true) as definition
            from pg_trigger tg
            join pg_class c on c.oid = tg.tgrelid
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and not tg.tgisinternal
            order by c.relname, tg.tgname) t), '[]'::json),
        -- OUR OWN functions only: extensions provide them by the hundred, and
        -- that is not our code. The body is taken as it is (`prosrc`): for
        -- plpgsql the database's parser does not parse it, and that is recorded
        -- as a separate, weaker class.
        'routines', coalesce((select json_agg(f) from (
            select p.oid::regprocedure::text as identity, p.proname as name,
                   case p.prokind when 'f' then 'function' when 'p' then 'procedure'
                                  when 'a' then 'aggregate' when 'w' then 'window'
                                  else p.prokind::text end as kind,
                   l.lanname as language,
                   pg_get_function_result(p.oid) as returns,
                   p.prosrc as body
            from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            join pg_language l on l.oid = p.prolang
            where n.nspname = 'public'
              and not exists (select 1 from pg_depend d
                              where d.objid = p.oid and d.deptype = 'e')
            order by p.proname) f), '[]'::json),
        'constraints', coalesce((select json_agg(c) from (
            select t.relname as table_name, con.conname as constraint_name,
                   con.contype::text as kind,
                   nullif(ref.relname, '') as ref_table,
                   -- Column names come from the catalogue rather than from a
                   -- regexp over the definition text: `CHECK ((age > 0))` does
                   -- not yield to a regexp.
                   (select string_agg(a.attname, ',' order by k.ord)
                    from unnest(con.conkey) with ordinality k(attnum, ord)
                    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum) as columns,
                   pg_get_constraintdef(con.oid, true) as definition
            from pg_constraint con
            join pg_class t on t.oid = con.conrelid
            join pg_namespace n on n.oid = t.relnamespace
            left join pg_class ref on ref.oid = con.confrelid
            where n.nspname = 'public'
            order by t.relname, con.conname) c), '[]'::json),
        'sequences', coalesce((select json_agg(s) from (
            select c.relname as name,
                   coalesce(t.relname || '.' || a.attname, '') as owned_by
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            left join pg_depend d on d.objid = c.oid and d.deptype = 'a'
            left join pg_class t on t.oid = d.refobjid
            left join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
            where n.nspname = 'public' and c.relkind = 'S'
            order by c.relname) s), '[]'::json)
      )
    SQL

    attr_reader :name, :cfg, :warnings

    def initialize(name)
      @name = name.to_s
      @cfg = Xref.source(@name)
      @warnings = []
    end

    def transport
      cfg[:transport].to_s
    end

    # => { 'server_version' =>, 'database' =>, 'tables' => [...], 'columns' => [...], 'indexes' => [...] }
    def fetch
      return fetch_thrift if transport == 'thrift'

      raw = case transport
            when 'activerecord'  then fetch_activerecord
            when 'ssh_psql'      then fetch_ssh_psql
            when 'structure_sql' then fetch_structure_sql
            else raise Error, "#{name}: неизвестный транспорт #{transport.inspect}"
            end

      raw = raw.to_s.strip
      raise Error, "#{name}: источник вернул пустой ответ" if raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise Error, "#{name}: ответ не разобран как JSON (#{e.message}); начало: #{raw.to_s[0, 200]}"
    end

    # Run arbitrary SQL over the same transport the schema is taken with.
    # Needed by the jsonb key collector: it has a query of its own but has to
    # travel to the same place.
    def run(sql)
      case transport
      when 'activerecord' then ActiveRecord::Base.connection.select_all(sql).rows.map { |r| r.join('|') }.join("\n")
      when 'ssh_psql' then ssh_psql(sql)
      else raise Error, "#{name}: транспорт #{transport.inspect} не умеет произвольный запрос"
      end
    end

    private

    # HBase goes into the same snapshot tables as PostgreSQL: a column family
    # is a `db_columns` row with the type `family`. What separates them is not
    # the structure but the KIND of the source (`sources.kind`) — otherwise a
    # table from the columnar store would merge with a PostgreSQL table of the
    # same name.
    def fetch_thrift
      # A connection of our own rather than the application's helper: that one
      # goes by an address from the environment, while we need the address from
      # the configuration. It also keeps us away from the application's own
      # pooled client.
      transport = Thrift::BufferedTransport.new(
        Thrift::Socket.new(cfg[:host].to_s, cfg[:port].to_i, THRIFT_TIMEOUT)
      )
      transport.open
      # The protocol wrapper is CONFIGURATION (`idioms.column_store_protocol`):
      # one particular application has its own, and its name has no business
      # sitting in the engine. Absent — the library's own protocol.
      client = Apache::Hadoop::Hbase::Thrift::Hbase::Client.new(binary_protocol(transport))

      tables = client.getTableNames.sort
      columns = tables.flat_map do |table|
        families = begin
          client.getColumnDescriptors(table).keys.sort
        rescue StandardError => e
          @warnings << "#{table}: семейства не прочитаны (#{e.class})"
          []
        end
        families.each_with_index.map do |family, index|
          { 'table_name' => table, 'column_name' => family, 'ordinal' => index + 1,
            'data_type' => 'family', 'not_null' => false, 'default_expr' => nil }
        end
      end

      { 'server_version' => 'hbase/thrift',
        'database' => "#{cfg[:host]}:#{cfg[:port]}",
        'tables' => tables.map { |t| { 'name' => t, 'kind' => 'hb', 'est_rows' => nil } },
        'columns' => columns,
        'indexes' => [] }
    ensure
      transport&.close
    end

    # The wrapper named in `idioms.column_store_protocol`, or the library's own
    # protocol. A name that does not resolve is said out loud rather than
    # silently replaced: a schema fetched through the wrong protocol would look
    # like an empty store.
    def binary_protocol(transport)
      wrapper = Xref.idioms[:column_store_protocol].to_s
      return Thrift::BinaryProtocol.new(transport) if wrapper.empty?

      begin
        Object.const_get(wrapper).binary_protocol(transport)
      rescue NameError
        raise Error, "#{name}: idioms.column_store_protocol = #{wrapper} — такой константы нет"
      end
    end

    def fetch_activerecord
      ActiveRecord::Base.connection.select_value(INTROSPECT_SQL)
    end

    # The container name in the configuration is a PATTERN, not an exact name.
    # Under an orchestrator the name carries a task suffix
    # (`pg_primary.1.new3ic22ln…`) which changes on every restart of the
    # service: on 2026-09-03 the schema refresh silently fell off in two
    # production data centres exactly that way, while the index went on
    # answering from a week-old snapshot. It is resolved on the far side — the
    # same trick as in Xref::RunPlaces.
    def ssh_psql(sql)
      out, err, status = Open3.capture3(
        'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
        cfg[:ssh_host].to_s, remote_psql_script,
        stdin_data: sql
      )
      unless status.success?
        raise Error, "#{name}: ssh #{cfg[:ssh_host]} вернул #{status.exitstatus}: #{Xref.utf8(err).strip.lines.last(3).join(' ').strip}"
      end

      # The answer goes into JSON.parse, and a schema can carry non-Latin text:
      # a comment on a table, a default like `default 'Нет'`, a function body.
      Xref.utf8(out)
    end

    def remote_psql_script
      match = Shellwords.escape("^#{Regexp.escape(cfg[:container].to_s)}(\\.|$)")
      psql = Shellwords.join(
        ['psql', '-U', cfg[:user].to_s, '-d', cfg[:database].to_s, '-At', '-q', '-f', '-']
      )
      <<~SH
        c=$(docker ps --format '{{.Names}}' | grep -E #{match} | head -1)
        if [ -z "$c" ]; then echo "контейнер по образцу #{cfg[:container]} не найден" >&2; exit 1; fi
        exec docker exec -i "$c" #{psql}
      SH
    end

    def fetch_ssh_psql
      ssh_psql(INTROSPECT_SQL)
    end

    # structure.sql is not parsed: it is loaded into a scratch database and
    # read with the same query as the live ones. That compares the repository
    # with production honestly, and no second, home-made schema parser appears.
    def fetch_structure_sql
      scratch = cfg[:scratch_database].to_s
      raise Error, "#{name}: не задана scratch_database" if scratch.empty?

      path = Xref.root.join(cfg[:path].to_s)
      raise Error, "#{name}: нет файла #{path}" unless File.exist?(path)

      Store.recreate_database!(scratch)

      _out, load_err, _status = Open3.capture3(
        'psql', '-d', scratch, '-q', '-v', 'ON_ERROR_STOP=0', '-f', path.to_s
      )
      failed = load_err.to_s.lines.grep(/ERROR:/)
      if failed.any?
        @warnings << "#{failed.size} операторов structure.sql не выполнилось (первая: #{failed.first.to_s.strip[0, 160]})"
      end

      out, err, status = Open3.capture3('psql', '-d', scratch, '-At', '-q', '-f', '-', stdin_data: INTROSPECT_SQL)
      raise Error, "#{name}: psql по временной базе вернул #{status.exitstatus}: #{Xref.utf8(err).strip}" unless status.success?

      Xref.utf8(out)
    end
  end
end
