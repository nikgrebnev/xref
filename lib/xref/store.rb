# frozen_string_literal: true

module Xref
  # The index store: a separate database on the local PostgreSQL with its own
  # connection, so that nothing is mixed into the application's own database.
  #
  # Snapshot history is kept (the last KEEP_SNAPSHOTS per source) — it shows
  # when a column appeared and in which data centre, not merely the current
  # state.
  module Store
    KEEP_SNAPSHOTS = 10

    # The abstract classes exist only for the sake of a separate connection pool.
    class Record < ActiveRecord::Base
      self.abstract_class = true
    end

    class Admin < ActiveRecord::Base
      self.abstract_class = true
    end

    DDL = <<~SQL
      create table if not exists sources (
        id         serial primary key,
        name       text not null unique,
        kind       text not null,
        transport  text not null,
        detail     jsonb not null default '{}'::jsonb
      );

      create table if not exists snapshots (
        id             serial primary key,
        source_id      integer not null references sources(id) on delete cascade,
        taken_at       timestamptz not null default now(),
        git_sha        text,
        server_version text,
        database_name  text,
        ok             boolean not null default true,
        error          text,
        warnings       text[] not null default '{}',
        duration_ms    integer
      );
      create index if not exists idx_snapshots_source on snapshots (source_id, taken_at desc);

      create table if not exists db_tables (
        snapshot_id integer not null references snapshots(id) on delete cascade,
        name        text not null,
        kind        text not null,
        est_rows    bigint,
        primary key (snapshot_id, name)
      );

      create table if not exists db_columns (
        snapshot_id  integer not null references snapshots(id) on delete cascade,
        table_name   text not null,
        column_name  text not null,
        ordinal      integer not null,
        data_type    text not null,
        not_null     boolean not null default false,
        default_expr text,
        primary key (snapshot_id, table_name, column_name)
      );
      create index if not exists idx_db_columns_name on db_columns (column_name);

      create table if not exists db_indexes (
        snapshot_id integer not null references snapshots(id) on delete cascade,
        table_name  text not null,
        index_name  text not null,
        is_unique   boolean not null default false,
        is_primary  boolean not null default false,
        definition  text not null,
        primary key (snapshot_id, table_name, index_name)
      );

      -- Rewrite rules, triggers, own functions, constraints and sequences. They
      -- are collected per source exactly like tables: "the rule exists in one
      -- data centre and not in another" is the same class of finding as a schema
      -- drift, and until 2026-10-07 it was invisible entirely.
      create table if not exists db_rules (
        snapshot_id integer not null references snapshots(id) on delete cascade,
        table_name  text not null,
        rule_name   text not null,
        event       text not null,
        is_instead  boolean not null default false,
        definition  text not null,
        primary key (snapshot_id, table_name, rule_name)
      );
      create index if not exists idx_db_rules_table on db_rules (table_name);

      create table if not exists db_triggers (
        snapshot_id   integer not null references snapshots(id) on delete cascade,
        table_name    text not null,
        trigger_name  text not null,
        function_name text,
        definition    text not null,
        primary key (snapshot_id, table_name, trigger_name)
      );

      -- `identity` is the name together with argument types: functions come
      -- overloaded, and one name is not enough for a key.
      create table if not exists db_routines (
        snapshot_id integer not null references snapshots(id) on delete cascade,
        identity    text not null,
        name        text not null,
        kind        text not null,
        language    text not null,
        returns     text,
        body        text,
        primary key (snapshot_id, identity)
      );
      create index if not exists idx_db_routines_name on db_routines (name);

      create table if not exists db_constraints (
        snapshot_id     integer not null references snapshots(id) on delete cascade,
        table_name      text not null,
        constraint_name text not null,
        kind            text not null,
        ref_table       text,
        columns         text,
        definition      text not null,
        primary key (snapshot_id, table_name, constraint_name)
      );
      -- The column was added later than the table itself: `create table if not
      -- exists` will not add it, and without this line the schema drifts from
      -- the code silently.
      alter table db_constraints add column if not exists columns text;
      create index if not exists idx_db_constraints_ref on db_constraints (ref_table) where ref_table is not null;

      create table if not exists db_sequences (
        snapshot_id integer not null references snapshots(id) on delete cascade,
        name        text not null,
        owned_by    text,
        primary key (snapshot_id, name)
      );

      -- Parsed bodies of rules, trigger functions and own functions. Kept apart
      -- from `code_refs`: these are not files but database objects, and their
      -- life cycle is per snapshot. They are mixed into the same views, so "a
      -- rule reads this column" stands next to "the code reads this column".
      create table if not exists db_refs (
        snapshot_id integer not null references snapshots(id) on delete cascade,
        object      text not null,
        object_kind text not null,
        kind        text not null,
        token       text not null,
        owner       text not null default '',
        detail      jsonb,
        primary key (snapshot_id, object, kind, token, owner)
      );
      create index if not exists idx_db_refs_kind on db_refs (kind, token);

      create table if not exists code_files (
        path       text primary key,
        sha        text not null,
        lang       text not null,
        bytes      integer,
        refs_count integer not null default 0,
        git_sha    text,
        indexed_at timestamptz not null default now()
      );

      create table if not exists code_refs (
        path   text not null references code_files(path) on delete cascade,
        kind   text not null,
        token  text not null,
        owner  text not null default '',
        count  integer not null default 1,
        lines  integer[] not null default '{}',
        detail jsonb,
        primary key (path, kind, token, owner)
      );
      -- A digest of the parse INPUTS: names from the schemas, the model map, the
      -- constant map. Without it a schema change is invisible while the file
      -- stays the same: the SHA is identical, but the candidate layer and the
      -- column-to-model binding are already different. That is exactly how the
      -- index insisted for a month that two tables were absent from two
      -- environments.
      alter table code_files add column if not exists inputs_sha text;
      -- The file's modification time is a GATE in front of hashing. The index
      -- catch-up computed the SHA of all 8,326 files on every command: 1.5 s out
      -- of the 4 that `bin/xref where` took. Walking them with `stat` costs
      -- 0.018 s — eighty times cheaper. Only those whose modification time
      -- differs from the remembered one are hashed; for the rest the previous
      -- SHA is trusted.
      --
      -- Modification time is not treated as proof by itself: if it differs, that
      -- means COMPUTE THE SHA, not "the file changed". Rewritten with identical
      -- content — the SHA matches and the parse is not repeated.
      alter table code_files add column if not exists mtime double precision;

      create index if not exists idx_code_refs_token on code_refs (token);
      create index if not exists idx_code_refs_kind on code_refs (kind, token);
      create index if not exists idx_code_refs_owner on code_refs (owner) where owner <> '';

      -- Facts from the running application. Replaced wholesale, with no
      -- history: this is a snapshot of the current code rather than of an
      -- external source.
      create table if not exists app_models (
        class_name  text primary key,
        table_name  text,
        path        text,
        primary_key text
      );
      -- The two columns used to carry one application's own jargon in their
      -- names, which is both a leak into the published copy and a divergence
      -- from the specification, where they have always been `places` and
      -- `env_id`. An existing index database gets the new columns; the stale
      -- ones are harmless, and their values are copied across by hand once.
      alter table app_jobs add column if not exists places text[] not null default '{}';
      alter table run_places add column if not exists env_id text not null default '';
      alter table app_models add column if not exists database text;
      alter table app_models add column if not exists base text;
      create index if not exists idx_app_models_table on app_models (table_name);

      create table if not exists app_associations (
        class_name  text not null,
        name        text not null,
        macro       text not null,
        target      text,
        foreign_key text,
        primary key (class_name, name)
      );

      create table if not exists app_routes (
        verb             text not null default '',
        path             text not null,
        controller       text not null default '',
        action           text not null default '',
        controller_class text,
        route_name       text,
        primary key (verb, path, controller, action)
      );

      create table if not exists app_controllers (
        class_name text primary key,
        path       text,
        actions    text[] not null default '{}'
      );

      create table if not exists app_jobs (
        job_key    text not null,
        class_name text not null,
        cron       text,
        places     text[] not null default '{}',
        path       text,
        primary key (job_key, class_name, cron)
      );

      -- The "constant -> file" map from the autoloader: through it a reference
      -- to a constant turns into an edge between files.
      create table if not exists app_constants (
        constant text primary key,
        path     text not null
      );
      create index if not exists idx_app_constants_path on app_constants (path);

      create table if not exists run_places (
        place     text primary key,
        env_id    text not null,
        ssh_host  text,
        container text
      );

      -- runit services, taken from the live containers.
      create table if not exists run_units (
        place     text not null,
        unit      text not null,
        command   text,
        rake_task text,
        taken_at  timestamptz not null default now(),
        primary key (place, unit)
      );

      -- Keys actually met inside jsonb columns. Not a schema but a sample.
      create table if not exists json_keys (
        source      text not null,
        table_name  text not null,
        column_name text not null,
        key         text not null,
        hits        integer not null default 0,
        sampled_at  timestamptz not null default now(),
        primary key (source, table_name, column_name, key)
      );
      create index if not exists idx_json_keys_key on json_keys (key);

      -- What the translation store holds, per language. Read from the files,
      -- BYPASSING I18n: fallbacks hide a gap, and `I18n.t` is green always.
      create table if not exists locale_keys (
        lang       text not null,
        key        text not null,
        file       text not null,
        primary key (lang, key, file)
      );
      create index if not exists idx_locale_keys_key on locale_keys (key);
      -- A second index on the same column, and it is not a duplicate: a plain
      -- btree under our string collation is NOT usable for `like 'prefix%'`, and
      -- that is exactly how keys under an assembled pattern are looked up
      -- (`t("theme_desktop.\#{name}")`). Without it those same 416 patterns
      -- scanned all 102,648 keys with a comparison.
      create index if not exists idx_locale_keys_key_prefix
        on locale_keys (key text_pattern_ops);

      -- Which environment keys are DEFINED in an environment. ONLY NAMES: the
      -- values are neither read nor transferred — `sed` cuts them on the node,
      -- before anything is sent.
      create table if not exists env_keys (
        place      text not null,
        name       text not null,
        checked_at timestamptz not null default now(),
        primary key (place, name)
      );

      -- Which migrations are applied in each environment. Data, not schema: the
      -- set of applied migrations lives in a table and has to be asked for
      -- separately.
      create table if not exists db_migrations (
        source      text not null,
        version     text not null,
        checked_at  timestamptz not null default now(),
        primary key (source, version)
      );

      -- Queries that actually RAN: a skeleton from the production logs and what
      -- is named inside it. There are no values here and there cannot be — the
      -- literals are replaced on the node. This is the only source that knows
      -- the RESOLVED table name where the code assembles it by interpolation.
      create table if not exists sql_runtime (
        place    text not null,
        host     text not null,
        day      date not null,
        digest   text not null,
        skeleton text not null,
        hits     bigint not null,
        tables   text[] not null default '{}',
        columns  text[] not null default '{}',
        filters  text[] not null default '{}',
        writes   text[] not null default '{}',
        parsed   boolean not null default false,
        primary key (place, host, day, digest)
      );
      create index if not exists idx_sql_runtime_day on sql_runtime (day desc);
      -- The "column in a condition" class was added later than the table
      -- itself: `create table if not exists` will not add it, and without this
      -- line the schema drifts silently.
      alter table sql_runtime add column if not exists filters text[] not null default '{}';

      -- Column fill rates from the LIVE data. The third level of proof next to
      -- the code and the schema: "nobody reads this column" and "there is
      -- nothing in this column" are different statements, and the question "what
      -- can be dropped" needs both.
      --
      -- `filled` is a meaningful value (not NULL, not an empty string); for a
      -- column with a default what matters is different — `off_default`, how
      -- many rows DIFFER from the default. With `default 1` a column nobody
      -- ever touched looks filled for every single row.
      -- `filled_recent` is for the recent cohort: a mechanism that has died is
      -- indistinguishable from a live one by the total count.
      create table if not exists column_fill (
        source        text not null,
        table_name    text not null,
        column_name   text not null,
        rows_total    bigint not null,
        rows_recent   bigint,
        filled        bigint not null,
        off_default   bigint,
        filled_recent bigint,
        recent_by     text,
        measured_at   timestamptz not null default now(),
        primary key (source, table_name, column_name)
      );

      -- Index scans: an index nobody reads is not "a redundant field", but its
      -- price is the same — space and work on every write.
      -- `since` is the moment the counters start from: a database restart resets
      -- them, and without that date "zero scans" means nothing.
      create table if not exists index_usage (
        source      text not null,
        table_name  text not null,
        index_name  text not null,
        scans       bigint not null,
        size_bytes  bigint not null,
        is_unique   boolean not null default false,
        is_primary  boolean not null default false,
        since       timestamptz,
        measured_at timestamptz not null default now(),
        primary key (source, table_name, index_name)
      );

      -- What was actually rendered, from the application logs.
      create table if not exists view_runtime (
        place    text not null,
        host     text not null,
        day      date not null,
        action   text not null default '',
        template text not null,
        path     text,
        hits     integer not null default 0,
        primary key (place, host, day, action, template)
      );
      create index if not exists idx_view_runtime_path on view_runtime (path);

      -- Which actions were requested (the `Processing by` lines) rather than
      -- which templates were rendered. The difference decides the question "is
      -- this route still needed": a redirect and a JSON response render no
      -- templates.
      create table if not exists action_runtime (
        place  text not null,
        host   text not null,
        day    date not null,
        action text not null,
        hits   integer not null default 0,
        primary key (place, host, day, action)
      );
      create index if not exists idx_action_runtime_action on action_runtime (action);

      -- The journal of verified findings: what was checked against the first
      -- source and how it ended.
      --
      -- The reason is a measurement rather than tidiness: in a new layer false
      -- findings outnumber real ones two or three to one (137 broken examples →
      -- 7, 632 broken links → 15, 22 missing translations → 6, 13 references to
      -- a non-existent column → 4). Each check cost half an hour of reading the
      -- first source, and all that knowledge used to stay in a commit message.
      -- The classes live in Xref::Verdicts::KINDS.
      --
      -- `path` and `file_sha` are the gate against the journal's main danger: a
      -- verdict of "false" HIDES a finding, which means it can hide a real
      -- problem that appeared later in the same place. The file changed — the
      -- verdict is stale and the finding is back. There is DELIBERATELY no
      -- foreign key to code_files: a file may disappear, and the verdict about
      -- it must remain and say so out loud.
      create table if not exists finding_verdicts (
        kind       text not null,
        subject    text not null,
        verdict    text not null,
        checked    text not null default 'глазами',
        reason     text not null default '',
        path       text,
        file_sha   text,
        git_sha    text,
        checked_at timestamptz not null default now(),
        primary key (kind, subject)
      );
      create index if not exists idx_finding_verdicts_path on finding_verdicts (path) where path is not null;

      -- Views are recreated as a whole: `create or replace` does not allow
      -- changing the set and the order of columns, and here they change as the
      -- index grows. The DROP itself is done BY THE CATALOGUE
      -- (Store.drop_views!) rather than by a list of names in this file: such a
      -- list is maintained by hand, and a name forgotten in it brings the very
      -- next run down with `already exists` — caught on 2026-10-10 with
      -- `v_search_blind`. The catalogue additionally removes views left over
      -- from earlier versions.

      -- The last successful snapshot of each source.
      create view v_current as
      select distinct on (s.source_id)
             s.id as snapshot_id, s.source_id, src.name as source, src.kind as source_kind,
             s.taken_at, s.git_sha, s.server_version, s.database_name
      from snapshots s
      join sources src on src.id = s.source_id
      where s.ok
      order by s.source_id, s.taken_at desc, s.id desc;

      -- PostgreSQL and the columnar store live in the same snapshot tables but
      -- in different namespaces: the same table name exists in both, and those
      -- are different things.
      create view v_tables as
      select c.source, t.name, t.kind, t.est_rows
      from db_tables t join v_current c on c.snapshot_id = t.snapshot_id
      where c.source_kind = 'pg';

      create view v_columns as
      select c.source, col.table_name, col.column_name, col.ordinal,
             col.data_type, col.not_null, col.default_expr
      from db_columns col join v_current c on c.snapshot_id = col.snapshot_id
      where c.source_kind = 'pg';

      create view v_indexes as
      select c.source, i.table_name, i.index_name, i.is_unique, i.is_primary, i.definition
      from db_indexes i join v_current c on c.snapshot_id = i.snapshot_id
      where c.source_kind = 'pg';

      -- HBase: tables and column families.
      create view v_hb_tables as
      select c.source, t.name
      from db_tables t join v_current c on c.snapshot_id = t.snapshot_id
      where c.source_kind = 'hbase';

      create view v_hb_families as
      select c.source, col.table_name, col.column_name as family
      from db_columns col join v_current c on c.snapshot_id = col.snapshot_id
      where c.source_kind = 'hbase';

      -- The code addresses a columnar-store table that is absent from the
      -- snapshot. The snapshot is taken from the test instance, so this is a
      -- reason to look rather than a verdict.
      create view v_hb_unknown_usage as
      select r.token as table_name, count(distinct r.path)::int as files,
             (array_agg(distinct r.path))[1:5] as sample
      from code_refs r
      left join v_hb_tables t on t.name = r.token
      where r.kind = 'hb_table' and t.name is null
      group by r.token;

      -- A family the table does not have: a typo or a forgotten migration.
      create view v_hb_unknown_family as
      select r.owner as table_name, split_part(r.token, ':', 1) || ':' as family,
             count(distinct r.path)::int as files,
             (array_agg(distinct r.path))[1:5] as sample
      from code_refs r
      join v_hb_tables t on t.name = r.owner
      left join v_hb_families f
        on f.table_name = r.owner and f.family = split_part(r.token, ':', 1) || ':'
      where r.kind = 'hb_column' and r.owner <> '' and f.family is null
      group by r.owner, split_part(r.token, ':', 1);

      -- Rules, triggers, functions, constraints and sequences of the current
      -- snapshot of each source.
      create view v_rules as
      select c.source, r.table_name, r.rule_name, r.event, r.is_instead, r.definition
      from db_rules r join v_current c on c.snapshot_id = r.snapshot_id;

      create view v_triggers as
      select c.source, t.table_name, t.trigger_name, t.function_name, t.definition
      from db_triggers t join v_current c on c.snapshot_id = t.snapshot_id;

      create view v_routines as
      select c.source, p.identity, p.name, p.kind, p.language, p.returns, p.body
      from db_routines p join v_current c on c.snapshot_id = p.snapshot_id;

      create view v_constraints as
      select c.source, k.table_name, k.constraint_name, k.kind, k.ref_table, k.columns, k.definition,
             case k.kind when 'p' then 'первичный ключ' when 'f' then 'внешний ключ'
                         when 'u' then 'уникальность' when 'c' then 'проверка'
                         when 'x' then 'исключение'
                         -- PG 18 keeps NOT NULL in pg_constraint alongside the
                         -- rest: that is a property of the column, not a
                         -- consumer of it.
                         when 'n' then 'not null' else k.kind end as kind_name
      from db_constraints k join v_current c on c.snapshot_id = k.snapshot_id;

      create view v_sequences as
      select c.source, s.name, s.owned_by
      from db_sequences s join v_current c on c.snapshot_id = s.snapshot_id;

      -- Constraints on a column: also a consumer. A column with a foreign key
      -- or a check cannot be touched silently — the database will not allow it,
      -- and that gets discovered in production.
      create view v_column_constraints as
      select k.source, k.table_name, trim(c.column_name) as column_name,
             k.constraint_name, k.kind, k.kind_name, k.ref_table, k.definition
      from v_constraints k
      cross join lateral unnest(string_to_array(coalesce(k.columns, ''), ',')) as c(column_name)
      where trim(c.column_name) <> '';

      -- A rule that does not exist everywhere: the same trouble as a table or a
      -- column missing somewhere, and it stays just as silent.
      create view v_rule_presence as
      select g.table_name, g.rule_name, g.present_in,
             array(select s.source from v_current s
                   where s.source_kind = 'pg' and not (s.source = any(g.present_in))
                   order by 1) as missing_in
      from (select table_name, rule_name, array_agg(source order by source) as present_in
            from v_rules group by table_name, rule_name) g;

      -- A table an insert into which may turn out to be something else.
      create view v_rewritten_tables as
      select table_name, array_agg(distinct rule_name order by rule_name) as rules,
             array_agg(distinct event order by event) as events,
             bool_or(is_instead) as has_instead,
             count(distinct source)::int as sources
      from v_rules group by table_name;

      -- Where a table exists and where it does not.
      create view v_table_presence as
      select g.name, g.present_in,
             array(select s.source from v_current s
                   where s.source_kind = 'pg'
                     and not (s.source = any(g.present_in)) order by 1) as missing_in
      from (select name, array_agg(source order by source) as present_in
            from v_tables group by name) g;

      create view v_column_presence as
      select g.table_name, g.column_name, g.present_in, g.types, g.types_by_source,
             array(select s.source from v_current s
                   where s.source_kind = 'pg'
                     and not (s.source = any(g.present_in)) order by 1) as missing_in
      from (select table_name, column_name,
                   array_agg(source order by source) as present_in,
                   array_agg(distinct data_type) as types,
                   array_agg(source || ':' || data_type order by source) as types_by_source
            from v_columns group by table_name, column_name) g;

      -- A table that does not exist everywhere.
      create view v_table_drift as
      select * from v_table_presence where cardinality(missing_in) > 0;

      -- A column that does not exist everywhere — but only for tables that do
      -- exist everywhere. Otherwise the report drowns in columns of backup
      -- tables from a single data centre.
      create view v_column_drift as
      select cp.* from v_column_presence cp
      join v_table_presence tp on tp.name = cp.table_name
      where cardinality(cp.missing_in) > 0 and cardinality(tp.missing_in) = 0;

      -- One column, different types in different sources.
      create view v_type_drift as
      select * from v_column_presence where cardinality(types) > 1;

      -- Where the code touches a table (the SQL was parsed by a parser — that is
      -- a fact).
      create view v_table_usage as
      select token as table_name, kind, path, count, lines
      from code_refs where kind in ('pg_table', 'pg_table_guess', 'hb_table');

      -- `mode` tells a read from a write. A column that is only written to must
      -- not vanish from the answers: that is not "unused" but "written into the
      -- void", and that is a different conversation.
      create view v_column_usage as
      select token as column_name, nullif(owner, '') as table_name, kind, path, count, lines,
             case kind when 'pg_column_write' then 'запись' else 'чтение' end as mode
      from code_refs where kind in ('pg_column', 'pg_column_write', 'ar_column', 'pg_column_expr')
      union all
      -- Bodies of rules and functions: the same column, but what touches it is
      -- the database rather than a file.
      select r.token, nullif(r.owner, ''), r.kind, r.object_kind || ' ' || r.object,
             1, '{}'::integer[],
             case r.kind when 'pg_column_write' then 'запись' else 'чтение' end
      from db_refs r
      join v_current c on c.snapshot_id = r.snapshot_id
      where r.kind in ('pg_column', 'pg_column_write');

      -- The lineage of a column's value: `insert into t (a) select x from u`
      -- means `u.x` arrives in `t.a`. The matching is positional — exactly as
      -- the database itself does it. An `expression` on the left means
      -- "computed in place, there is no source column".
      create view v_column_lineage as
      select split_part(r.token, '.', 1) as table_name,
             split_part(r.token, '.', 2) as column_name,
             split_part(r.owner, '.', 1) as from_table,
             split_part(r.owner, '.', 2) as from_column,
             r.owner as source, r.detail->>'via' as via,
             -- The alias of a subquery or a CTE is not a table: `d.cnt` is a
             -- name inside the query, and the chain upwards legitimately ends
             -- there.
             case when r.owner = 'выражение' then 'выражение'
                  -- `new`/`old` in a rule body is THE INCOMING ROW rather than
                  -- a subquery: 252 links out of 281 were wrongly called
                  -- subqueries.
                  when split_part(r.owner, '.', 1) in ('new', 'old') then 'новая строка'
                  when exists (select 1 from v_table_presence tp
                               where tp.name = split_part(r.owner, '.', 1)) then 'таблица'
                  else 'подзапрос' end as source_kind,
             r.path, r.lines
      from code_refs r where r.kind = 'col_lineage'
      union all
      select split_part(r.token, '.', 1), split_part(r.token, '.', 2),
             split_part(r.owner, '.', 1), split_part(r.owner, '.', 2),
             r.owner, coalesce(r.detail->>'via', 'rule'),
             case when r.owner = 'выражение' then 'выражение'
                  when split_part(r.owner, '.', 1) in ('new', 'old') then 'новая строка'
                  when exists (select 1 from v_table_presence tp
                               where tp.name = split_part(r.owner, '.', 1)) then 'таблица'
                  else 'подзапрос' end,
             r.object_kind || ' ' || r.object, '{}'::integer[]
      from db_refs r join v_current c on c.snapshot_id = r.snapshot_id
      where r.kind = 'col_lineage';

      -- Column lists substituted into a query as a whole. For a column from
      -- such a list this is the only place where it is named.
      create view v_column_lists as
      select path, token as name, owner as scope,
             coalesce(array(select jsonb_array_elements_text(detail->'columns')), '{}') as columns,
             coalesce((detail->>'size')::int, 0) as size,
             -- Duplicates inside the list: the set is stored without them, but
             -- the fact of a duplicate is a finding rather than noise (see
             -- v_column_list_defect).
             coalesce(detail->'dups', '{}'::jsonb) as dups, lines
      from code_refs where kind = 'col_list';

      -- Is the column's VALUE taken by key: `row['member_messenger']`,
      -- `info.fetch(:sex)`. For tables selected with a whole field list this is
      -- the only real proof of use: a name in the list is not a use, it is named
      -- there once and for all the columns at once.
      --
      -- The table is known where it is visible WHICH query filled the result
      -- row: `res = select_all("select * from member_contacts …")` and below
      -- `res.each { |line| line['contact'] }`. Where it is not visible (the row
      -- came back from somebody else's method, the query named two tables) the
      -- owner is empty, and the strength of the link stays A NAME. The report
      -- must say which of the two cases it is looking at.
      create view v_column_value_read as
      select token as column_name, nullif(owner, '') as table_name, path, lines, count
      from code_refs where kind = 'key_read';

      -- A key assembled by interpolation but with a known PATTERN:
      -- `info["language\#{num}_2"]` yields `language$1_2`. A column of a series
      -- is recognisable by such a pattern — and that is a use, not a non-use.
      create view v_column_key_pattern as
      select token as pattern, path, detail->>'expr' as expr, detail->>'scope' as scope, lines
      from code_refs where kind = 'key_pattern';

      -- A name assembled by interpolation anywhere in the code: `g$1`,
      -- `language$1_2`. A column of a series cannot be found by word — its name
      -- does not exist in the tree at all.
      create view v_name_pattern as
      select token as pattern, path, detail->>'expr' as expr, detail->>'scope' as scope, lines
      from code_refs where kind = 'name_pattern';

      -- Access by a variable key: `row[field]` in a loop over a field list.
      -- Which column that is stays unknown; staying silent about it is not
      -- allowed, otherwise "the value is taken nowhere" is passed off as a fact
      -- where it simply is not visible.
      -- `on` is the receiver: without it this kind lumps together `row[field]`
      -- (a possible column read) and `ids[i]` (an ordinary array access), and
      -- the tree holds more of the latter. The blindness count over columns was
      -- overstated because of that.
      create view v_column_key_dynamic as
      select path, nullif(owner, '') as table_name, detail->>'expr' as expr,
             detail->>'on' as on_what, detail->>'scope' as scope, lines, count
      from code_refs where kind = 'key_dynamic';

      -- `select *`, and what is REALLY taken out of that row.
      --
      -- The star is the last big assumption in the answer "which fields we do
      -- not use": the report holds that listing every column proves nothing,
      -- otherwise no column would ever come out unused. The decision is right,
      -- but it was a CHOICE rather than a measurement.
      --
      -- The measurement is here. Out of a starred row the code takes the
      -- `keys_read` of columns from `columns`, and the star hides exactly one
      -- thing: an access where THE KEY IS A VARIABLE.
      --
      -- Such accesses come in two classes, and they must not be mixed.
      -- `keys_dynamic` are accesses known FOR CERTAIN to be on a row of this
      -- table. `keys_dynamic_file` are accesses with an unknown table but IN THE
      -- SAME FILES where the table is selected with a star: their table is
      -- unknown, which means it could be this one. In a file that never goes to
      -- the table — it could not.
      --
      -- Both zeroes together are what constitutes the proof: the star hides
      -- nothing, and "this column is not read" is a fact rather than an
      -- assumption.
      create view v_star_coverage as
      with star as (select owner as table_name, count(distinct path)::int as files,
                           sum(count)::int as places
                    from code_refs where kind = 'pg_select_star' and owner <> '' group by 1)
      select s.table_name, s.files, s.places,
             (select count(distinct r.token)::int from code_refs r
              where r.kind = 'key_read' and r.owner = s.table_name) as keys_read,
             (select count(distinct r.token)::int from code_refs r
              where r.kind = 'key_pattern' and r.owner = s.table_name) as key_patterns,
             (select coalesce(sum(r.count), 0)::int from code_refs r
              where r.kind = 'key_dynamic' and r.owner = s.table_name) as keys_dynamic,
             (select coalesce(sum(r.count), 0)::int from code_refs r
              where r.kind = 'key_dynamic' and r.owner = ''
                and r.path in (select x.path from code_refs x
                               where x.kind = 'pg_select_star' and x.owner = s.table_name)
             ) as keys_dynamic_file,
             (select count(distinct c.column_name)::int from v_columns c
              where c.table_name = s.table_name) as columns
      from star s;

      -- A column of a table: is it read, written, or neither. Parsed SQL is a
      -- fact; accesses through the ORM count as reads, because the arguments of
      -- `where`/`order` cannot tell a write apart.
      create view v_column_rw as
      select cp.table_name, cp.column_name,
             array_to_string(cp.types_by_source, ', ') as types,
             coalesce(r.files, 0) as read_files, coalesce(w.files, 0) as write_files,
             coalesce(a.files, 0) as orm_files, coalesce(k.files, 0) as key_files,
             coalesce(k.test_files, 0) as key_test_files, coalesce(kt.files, 0) as key_table_files,
             coalesce(d.reads, 0) as db_reads, coalesce(d.writes, 0) as db_writes
      from v_column_presence cp
      left join (select owner, token, count(distinct path)::int as files
                 from code_refs where kind = 'pg_column' group by 1, 2) r
        on r.owner = cp.table_name and r.token = cp.column_name
      left join (select owner, token, count(distinct path)::int as files
                 from code_refs where kind = 'pg_column_write' group by 1, 2) w
        on w.owner = cp.table_name and w.token = cp.column_name
      left join (select owner, token, count(distinct path)::int as files
                 from code_refs where kind = 'ar_column' group by 1, 2) a
        on a.owner = cp.table_name and a.token = cp.column_name
      -- Taking a value by key, and a name inside a string expression
      -- (`'a-b<interval'`): the link is by NAME and has no table.
      --
      -- Specs and scripts are counted SEPARATELY: a test does not make a column
      -- necessary to the product. Without that split a single spec declared a
      -- column used — and the list "not used in the code" silently lost rows.
      left join (select token,
                        count(distinct path) filter (
                          where path not like 'spec/%' and path not like 'script/%')::int as files,
                        count(distinct path) filter (
                          where path like 'spec/%' or path like 'script/%')::int as test_files
                 from code_refs where kind in ('key_read', 'pg_column_expr') group by 1) k
        on k.token = cp.column_name
      -- The same link, but WITH A TABLE: it is visible which query filled the
      -- result row. The link by name stays alongside and is not replaced —
      -- otherwise columns whose table could not be traced would all land in
      -- "not used", and that is an error in the dangerous direction.
      left join (select owner, token, count(distinct path) filter (
                          where path not like 'spec/%' and path not like 'script/%')::int as files
                 from code_refs where kind = 'key_read' and owner <> '' group by 1, 2) kt
        on kt.owner = cp.table_name and kt.token = cp.column_name
      -- Reads and writes FROM THE DATABASE: an accumulating rule reads the
      -- column it increments, and without this it would be listed as unread.
      left join (select r.owner, r.token,
                        count(distinct r.object) filter (where r.kind = 'pg_column')::int as reads,
                        count(distinct r.object) filter (where r.kind = 'pg_column_write')::int as writes
                 from db_refs r join v_current c on c.snapshot_id = r.snapshot_id
                 group by 1, 2) d
        on d.owner = cp.table_name and d.token = cp.column_name;

      -- A column's fill rate from the live data, per source. `verdict` collapses
      -- the measurement into a word, because three numbers side by side get
      -- misread: "empty" is a removal candidate, "never differs from the
      -- default" is a dummy column, and "not filled for new rows" is a dead
      -- mechanism whose data remains.
      create view v_column_fill as
      select source, table_name, column_name, rows_total, rows_recent, filled, off_default,
             filled_recent, recent_by, measured_at,
             case when filled = 0 then 'пусто'
                  when off_default = 0 then 'всё по умолчанию'
                  -- Seventeen rows out of three million is also "nobody touched
                  -- it": a threshold is needed, otherwise a dummy column looks
                  -- alive.
                  when off_default is not null and rows_total > 0
                       and off_default < rows_total / 1000 then 'умолчание почти у всех'
                  when rows_recent > 0 and filled_recent = 0 then 'у новых не заполняется'
                  -- The share in the recent cohort is ten times below the
                  -- overall one — the mechanism is fading, and the total count
                  -- does not show that at all: one column had 141,006 filled
                  -- rows in total and one over the year.
                  when rows_recent > 0 and filled > 0
                       and filled_recent::numeric / rows_recent < (filled::numeric / rows_total) / 10
                    then 'у новых почти не заполняется'
                  else 'заполняется' end as verdict,
             case when rows_total > 0 then round(100.0 * filled / rows_total, 2) else 0 end as share
      from column_fill;

      -- An index nobody has read since the counters were reset. Not "a
      -- redundant field", but the price is the same: space and work on every
      -- write.
      create view v_index_unused as
      select source, table_name, index_name, size_bytes, since, measured_at,
             pg_size_pretty(size_bytes) as size
      from index_usage
      where scans = 0 and not is_primary and not is_unique;

      -- Blind spots: the name is assembled at runtime, the parser gave up, the
      -- file was not parsed. A blind spot is only what REMAINED unknown. If a
      -- table name is assembled from a variable and the variable is assigned
      -- nearby, there is an answer (`detail->>'resolved'`), and keeping that in
      -- a count of ignorance means lying about oneself.
      create view v_blind as
      select path, kind, token, count, lines, detail
      from code_refs
      where kind in ('sql_blind', 'hb_dynamic', 'scan_error')
        and detail->>'resolved' is null;

      -- Resolved: the name is assembled at runtime but was found through an
      -- assignment.
      create view v_blind_resolved as
      select path, token, detail->>'resolved' as table_name, lines, count
      from code_refs where kind = 'sql_blind' and detail->>'resolved' is not null;

      -- FILES THE TEXT SEARCH CANNOT SEE. A zero byte inside makes a file
      -- binary for `rg` and `git grep`: the first returns nothing and exits with
      -- the code for "not found", the second prints "Binary file … matches"
      -- instead of the lines. The parse does read such a file, so the index
      -- knows about it — and is obliged to say so out loud, otherwise "this is
      -- not in the tree" would be a lie.
      create view v_search_blind as
      select f.path, f.lang, f.bytes
      from code_files f
      where exists (select 1 from code_refs r where r.path = f.path and r.kind = 'search_blind');

      -- Documentation as a layer of the index.
      --
      -- 12,243 files out of 23,337 are `.md`, and before this parse the index
      -- knew nothing about them. A document is as much a source of statements
      -- about the tree as code is, and it ages SILENTLY: a link to a removed
      -- file still looks like a link, and the name of a removed table reads as
      -- current.
      --
      -- The record kinds are its own (`doc_*`) deliberately: a mention of a
      -- table in a document is NOT an access to the table. Mixing them means
      -- declaring used whatever has merely been written about.
      create view v_doc_link as
      select path as doc, token as target, owner as kind, lines,
             detail->>'label' as label
      from code_refs where kind = 'doc_link';

      -- A link leading nowhere: the target does not exist. Kept apart from the
      -- rest, because this is a finding rather than information.
      create view v_doc_link_broken as
      select doc, target, kind, lines, label
      from v_doc_link where kind = 'НЕТ ТАКОГО ФАЙЛА';

      -- A mention of a file of the tree in backticks. `kind` tells an existing
      -- path from a non-existent one and from "looks like a path" — the last
      -- being an illustrative example in a document, and not counted as a
      -- finding.
      create view v_doc_path as
      select path as doc, token as target, owner as kind, lines, count
      from code_refs where kind = 'doc_path';

      -- Sections of a document: through them an answer points at a PLACE rather
      -- than merely at a file.
      create view v_doc_heading as
      select path as doc, token as heading, owner::int as level, lines
      from code_refs where kind = 'doc_heading';

      -- Code blocks and their class. The classes are the main thing here: "did
      -- not parse" without them was a false alarm over 137 blocks, of which
      -- fourteen turned out real. A sketch with human omissions, a fragment cut
      -- off mid-branch, a patch and a foreign dialect are not defects of the
      -- example.
      create view v_doc_code as
      select path as doc,
             case kind
               when 'doc_code' then 'блок'
               when 'doc_code_sketch' then 'набросок'
               when 'doc_code_excerpt' then 'отрывок'
               when 'doc_code_fragment' then 'кусок запроса'
               when 'doc_code_patch' then 'заплатка'
               when 'doc_code_dialect' then 'другой диалект'
               when 'doc_code_broken' then 'НЕ РАЗОБРАЛСЯ'
             end as verdict,
             token as lang, owner as detail, lines,
             coalesce((detail->>'lines')::int, 0) as size
      from code_refs
      where kind in ('doc_code', 'doc_code_sketch', 'doc_code_excerpt', 'doc_code_fragment',
                     'doc_code_patch', 'doc_code_dialect', 'doc_code_broken');

      -- Names from the database named in documents ON PURPOSE: in backticks or
      -- in an SQL block. Words of prose do not come here — otherwise 157 MB of
      -- documents would match every phrase of the form "in the table below".
      create view v_doc_name as
      select path as doc, token as name,
             case kind when 'doc_table' then 'таблица в запросе'
                       when 'doc_column' then 'колонка в запросе'
                       else 'имя в кавычках' end as how,
             lines, count
      from code_refs where kind in ('doc_name', 'doc_table', 'doc_column');

      -- A document names a table that is IN NO schema snapshot. This is a
      -- question rather than a verdict: a removed table looks like this, and so
      -- does one not yet created (we keep plans with proposed tables). So
      -- alongside it the report prints whether any code touches it: if not, the
      -- document is almost certainly about the past or about the future rather
      -- than about today.
      create view v_doc_table_unknown as
      select n.name as table_name, count(distinct n.doc)::int as docs,
             array_agg(distinct n.doc order by n.doc) as docs_list,
             exists (select 1 from code_refs r
                     where r.kind in ('pg_table', 'pg_table_guess') and r.token = n.name) as in_code
      from v_doc_name n
      where n.how = 'таблица в запросе'
        and not exists (select 1 from v_tables t where t.name = n.name)
        and not exists (select 1 from db_routines d join v_current c on c.snapshot_id = d.snapshot_id
                        where d.name = n.name)
      group by 1;

      -- Which documents describe this file. Needed by the per-file reports:
      -- "who wrote about this" is as legitimate a question as "who calls this".
      create view v_doc_for_path as
      select target as path, doc, kind, lines
      from v_doc_path where kind = 'есть'
      union all
      select target as path, doc, 'ссылка' as kind, lines
      from v_doc_link where kind = 'файл';

      -- The code calls a key; is it in the store, and in which languages. `en`
      -- and `ru` separately: those two are what cover the rest through
      -- fallbacks, and if they are missing a human sees either "translation
      -- missing" or a foreign language.
      -- A key can also be a NAMESPACE: `t('texts_about_us')` returns a hash, and
      -- the code walks it as a list. Without accounting for that such keys
      -- landed in "no translation" while all the texts sit underneath them.
      --
      -- Written as a DECOMPOSITION OF THE KEY INTO PREFIXES rather than as
      -- `like token || '.%'`, and the reason is the price: six `LIKE`
      -- subqueries for each of 2,699 accesses cost 1.5 s for one pass, and the
      -- report does four. The prefixes (`a.b.c` → `a`, `a.b`, `a.b.c`) are
      -- joined by EQUALITY, that is, by hash.
      --
      -- Incidentally that is also more honest: in `LIKE` an underscore is a
      -- wildcard, and key names are full of them, so `user_name.%` also matched
      -- `userXname.foo`. Compared on our data: the previous answer and this one
      -- agree key for key.
      create view v_i18n_usage as
      with store as (
        -- THE LANGUAGES ARE A LIST, not two columns named after two of them.
        -- `has_en`/`has_ru` were baked in, so a tree whose main pair is another
        -- one had to patch the view and the report — and a patch is what an
        -- update carries away. Which languages MUST be there is a habit of a
        -- tree (`idioms.main_locales`), and the report asks that list.
        select key, array_agg(distinct lang order by lang) as langs_list,
               count(distinct lang)::int as langs
        from locale_keys where key <> '' group by key
      ),
      -- A key and each of its dotted prefixes: through one it is visible as part
      -- of a namespace that is called as a whole.
      covered as (
        select s.key, s.key as ancestor, s.langs_list from store s
        union all
        select s.key, array_to_string((string_to_array(s.key, '.'))[1:i], '.'), s.langs_list
        from store s
        cross join generate_series(1, coalesce(array_length(string_to_array(s.key, '.'), 1), 1) - 1) as i
      ),
      cover as (
        -- The languages of a namespace are the union of the languages of its
        -- keys: a key called as a whole namespace exists in a language if
        -- anything under it does.
        select ancestor as token,
               array_agg(distinct lang order by lang) as langs_list
        from covered, unnest(langs_list) as lang group by 1
      ),
      refs as (
        select token, count(distinct path)::int as files,
               array_agg(distinct path order by path) as paths,
               -- An access can carry a FALLBACK TEXT: `t('x', default:
               -- 'Refresh')` will never show "translation missing", and it has
               -- no place in a list of gaps. Without this class three findings
               -- out of 22 were false.
               bool_or(coalesce((detail->>'default')::boolean, false)) as has_default
        from code_refs where kind = 'i18n_key' group by token
      )
      select r.token as key, r.files, r.paths, r.has_default,
             c.token is not null as in_store,
             coalesce(c.langs_list, '{}') as langs_list,
             -- The number of languages belongs to THE KEY ITSELF rather than to
             -- the namespace: a key that does not exist has zero languages, and
             -- that is a different statement.
             coalesce(s.langs, 0) as langs
      from refs r
      left join cover c on c.token = r.token
      left join store s on s.key = r.token;

      -- A key exists in the store but nothing calls it. An orphaned text: it
      -- gets translated into eighteen languages and there is nothing to show it.
      -- Three ways in which a key from the store can be DEMANDED by the code.
      -- Pulled into a separate view not for beauty but for the price: orphans
      -- used to be computed with three `not exists` holding `LIKE` inside, and
      -- each of them scanned every access for each of 102,648 keys.
      -- `bin/xref texts` answered in 318 seconds — that is, it did not answer.
      --
      -- The same three rules, written so that an index can work:
      --   1. the key is called literally — a lookup over `code_refs.token`;
      --   2. a NAMESPACE is called: `t('about')` returns a hash and every key
      --      under it works. Instead of `k.key like r.token || '.%'` (a scan of
      --      the accesses) THE KEY ITSELF is decomposed into dotted prefixes
      --      which are looked up by index: for `a.b.c` that is `a` and `a.b`,
      --      two operations instead of thousands;
      --   3. an assembled key is called: `t("theme_desktop.\#{name}")` covers a
      --      whole namespace. The pattern must be SELECTIVE (its literal part no
      --      shorter than four characters): `$1` on its own matches any key and
      --      explains everything at once, that is, nothing. Here the scan goes
      --      from THE PATTERN (there are 416 of them) rather than from the key,
      --      and its literal prefix narrows the range by index — so the full
      --      comparison falls to a handful.
      -- The tiers are computed IN ORDER, and that is not style but price. The
      -- third tier (comparison against the patterns) produces 336,170 matches
      -- and costs 2.7 s when run over all 102,648 keys. But a key already
      -- demanded literally or through a namespace does not need the third tier
      -- at all — and after that filtering only a few per cent remain. The answer
      -- is the same: a key covered by the first two enters the union from them.
      -- Both sides are reduced to DISTINCT values before the join, and that is
      -- not cosmetic. The store holds 102,648 rows for 8,959 keys (a row per
      -- language and file), while the accesses hold 11,087 records for 2,699
      -- keys (a record per file). Joining them as they lie produced 179,139
      -- pairs instead of 2,699 and forced a sort over hundreds of thousands of
      -- rows — hence the seconds.
      create view v_locale_called as
      with keys as (select distinct key from locale_keys where key <> ''),
      called as (select distinct token from code_refs where kind = 'i18n_key'),
      named as (
        select k.key from keys k join called r on r.token = k.key
        union
        select k.key
        from keys k
        cross join lateral (
          select array_to_string((string_to_array(k.key, '.'))[1:i], '.') as prefix
          from generate_series(1, coalesce(array_length(string_to_array(k.key, '.'), 1), 1) - 1) as i
        ) pre
        join called r on r.token = pre.prefix
      )
      select key from named
      union
      select k.key
      from keys k
      join (select distinct token from code_refs
            where kind = 'i18n_dynamic' and length(replace(token, '$1', '')) >= 4) d
        on k.key like split_part(d.token, '$1', 1) || '%'
       and k.key like replace(d.token, '$1', '%')
      where not exists (select 1 from named n where n.key = k.key);

      -- A key exists in the store but nothing calls it. An orphaned text: it
      -- gets translated into eighteen languages and there is nothing to show it.
      create view v_locale_orphan as
      select k.key, count(distinct k.lang)::int as langs,
             array_agg(distinct k.file order by k.file) as files
      from locale_keys k
      where k.key <> ''
        and not exists (select 1 from v_locale_called c where c.key = k.key)
      group by 1;

      -- The code reads an environment key; where it is defined and where it is
      -- not. A `nil` from an empty key arrives SILENTLY, so "defined nowhere" is
      -- a finding rather than a detail.
      create view v_env_usage as
      select r.token as name, count(distinct r.path)::int as files,
             array_agg(distinct r.path order by r.path) as paths,
             -- Production code against the arguments of rake tasks: `rake x
             -- LIMIT=10` reads the same `ENV['LIMIT']`, but such a key must not
             -- be defined in an environment. Without that split the report
             -- starts with `APPLY`, `LIMIT`, `DAYS` and people stop reading it
             -- on the third line.
             count(distinct r.path) filter (
               where (r.path like 'app/%' or r.path like 'config/%'
                      or (r.path like 'lib/%' and r.path not like 'lib/tasks/%'))
                 and r.path not like 'spec/%')::int as app_files,
             count(distinct r.path) filter (
               where r.path like 'lib/tasks/%' or r.path like 'script/%')::int as task_files,
             array(select k.place from env_keys k where k.name = r.token order by k.place) as set_in,
             -- Whether the read has a fallback value. Without this class a real
             -- hole ("the key is missing, `nil` will arrive") lies in one pile
             -- with the ordinary setting `ENV.fetch('X', 'default')`.
             exists (select 1 from code_refs d where d.kind = 'env_default' and d.token = r.token) as has_default,
             -- Read as a FLAG (`if ENV['X']`): an empty value is legitimate
             -- there and means "switched off". Without this class the list "the
             -- key is missing" comes out a hundred and thirty-eight lines long
             -- and becomes useless.
             exists (select 1 from code_refs f where f.kind = 'env_flag' and f.token = r.token) as is_flag,
             -- WHAT reads the key. While only Ruby was parsed, 284 keys read by
             -- shell scripts and 43 read from `.yml` through ERB were entirely
             -- invisible — while the report claimed "not read in the code".
             count(distinct r.path) filter (where r.path like '%.sh' or r.path like '%.bash')::int as sh_files,
             count(distinct r.path) filter (where r.path like '%.yml' or r.path like '%.yaml')::int as conf_files
      from code_refs r where r.kind = 'env_key' group by 1;

      -- JavaScript and Stimulus.
      --
      -- 431 files sat in the index and yielded nothing but word matches: the
      -- reachability graph broke off at `app/javascript`, and the chain
      -- "template → controller → its method" did not exist at all while
      -- `data-controller` appeared in 1,022 templates.
      --
      -- THE REGISTRY is the only authority in this layer. A name from a
      -- template means something only if it is registered: `data-bs-target` is
      -- Bootstrap rather than Stimulus, and without the registry it ended up
      -- among the findings.
      create view v_stimulus_registry as
      select r.token as identifier, r.owner as class_name, r.path as registered_in,
             c.path as source,
             (select count(*) from code_refs m
              where m.kind = 'js_method' and m.path = c.path)::int as methods,
             (select count(*) from code_refs t
              where t.kind = 'stimulus_target' and t.path = c.path)::int as targets,
             (select count(*) from code_refs v
              where v.kind = 'stimulus_value' and v.path = c.path)::int as values_declared,
             (select count(distinct u.path) from code_refs u
              where u.kind = 'stimulus_use' and u.token = r.token)::int as templates
      from code_refs r
      left join code_refs c on c.kind = 'js_class' and c.token = r.owner
      where r.kind = 'stimulus_register';

      -- A template attaching a controller. `kind` tells a registered one from an
      -- unregistered one: the latter means NOTHING WILL HAPPEN — Stimulus
      -- silently ignores an unknown name.
      create view v_stimulus_use as
      select u.path, u.token as identifier, u.lines,
             exists (select 1 from code_refs r
                     where r.kind = 'stimulus_register' and r.token = u.token) as registered
      from code_refs u where u.kind = 'stimulus_use';

      -- An action from a template against a method of the controller. The most
      -- valuable check of this layer: `data-action="click->x#method"` pointing at
      -- a non-existent method does not fail — nothing happens.
      create view v_stimulus_action as
      select a.path, a.owner as identifier, a.token as method, a.lines,
             g.source, g.class_name,
             case
               when g.identifier is null then 'контроллер не зарегистрирован'
               when g.source is null then 'класс не найден в дереве'
               when exists (select 1 from code_refs m
                            where m.kind = 'js_method' and m.path = g.source and m.token = a.token)
                 then 'метод есть'
               else 'МЕТОДА НЕТ'
             end as verdict
      from code_refs a
      left join v_stimulus_registry g on g.identifier = a.owner
      where a.kind = 'stimulus_action';

      -- A target from a template against the declaration. Three caveats, each
      -- of which would otherwise yield a false finding:
      --   * the middle is not registered — then it is not Stimulus at all
      --     (bootstrap);
      --   * the target name is not a name but a SELECTOR (`#birthday_div`):
      --     the controller reads such an attribute itself, it is not a Stimulus
      --     target;
      --   * the controller declares NO targets at all — then the attribute is
      --     its own rather than a broken target.
      create view v_stimulus_target as
      select t.path, t.owner as identifier, t.token as target, t.lines,
             case
               when g.identifier is null then 'не Stimulus'
               when t.token !~ '^[A-Za-z_$][A-Za-z0-9_$]*$' then 'селектор, а не имя цели'
               when g.targets = 0 then 'контроллер целей не объявляет'
               when exists (select 1 from code_refs d
                            where d.kind = 'stimulus_target' and d.path = g.source and d.token = t.token)
                 then 'цель объявлена'
               else 'ЦЕЛЬ НЕ ОБЪЯВЛЕНА'
             end as verdict
      from code_refs t
      left join v_stimulus_registry g on g.identifier = t.owner
      where t.kind = 'stimulus_target_use';

      -- A module edge: `require`/`import` with a resolved path. It enters
      -- v_code_edges, so reachability stops breaking off at JavaScript.
      create view v_js_edges as
      select path as from_path, '' as scope, token as to_path, 'import' as kind
      from code_refs where kind = 'js_import';

      -- A JavaScript file no import reaches.
      --
      -- The class decides everything, and it is the same lesson as with
      -- documents. Of 70 such files sixteen are BUILD ROOTS
      -- (`app/javascript/packs`): nothing imports them by construction, the
      -- bundler starts from them. Fifty-four are standalone scripts (`script/`)
      -- that are run directly. Calling them dead means issuing seventy findings
      -- where there are none.
      create view v_js_unreachable as
      select f.path, f.bytes,
             case
               when f.path like 'app/javascript/packs/%' then 'корень сборки'
               when f.path like 'script/%' then 'самостоятельный скрипт'
               when f.path like 'public/%' then 'отдаётся как файл'
               when f.path like 'vendor/%' then 'поставляемая зависимость'
               when exists (select 1 from code_refs e
                            where e.kind = 'js_entry' and e.token = f.path) then 'корень из конфига сборки'
               -- Three classes of files nothing imports and which are alive
               -- nonetheless: what reads them is a tool rather than code.
               -- Without them eight such files stood as removal candidates and
               -- would have hidden a genuinely dead controller (a second
               -- project, 2026-10-09).
               when f.path like '%.d.ts' then 'объявление типов (читает tsc)'
               when f.path like '%.test.ts' or f.path like '%.spec.ts'
                 or f.path like '%.test.js' or f.path like '%.spec.js' then 'прогон тестов'
               when f.path like '%.config.ts' or f.path like '%.config.js'
                 or f.path like '%.config.mjs' then 'настройка сборки'
               else 'КАНДИДАТ НА СНЯТИЕ'
             end as kind,
             exists (select 1 from v_doc_for_path d where d.path = f.path) as in_docs
      from code_files f
      where f.lang = 'js'
        and not exists (select 1 from v_js_edges e where e.to_path = f.path);

      -- The front-end configuration (nginx/angie): blocks, directives and four
      -- defects, each of which has cost an incident once.
      --
      -- In a front-end config an error does not fail — it quietly starts
      -- serving the wrong thing, so the report about these has to speak up.
      create view v_conf_directive as
      select path, token as directive, owner as args, detail->>'scope' as scope, lines
      from code_refs where kind = 'conf_directive';

      create view v_conf_block as
      select path, owner as block, token as args, detail->>'scope' as scope, lines
      from code_refs where kind = 'conf_block';

      create view v_conf_defect as
      select path, token as defect, owner as detail, detail->>'rule' as rule, lines
      from code_refs where kind = 'conf_defect';

      -- The composition of services AS DECLARED (as opposed to v_places — as it
      -- runs). Four questions: which image, which keys, what is mounted, which
      -- port.
      create view v_compose_service as
      select path, token as service, nullif(owner, '') as image, lines
      from code_refs where kind = 'compose_service';

      create view v_compose_detail as
      select path, owner as service,
             case kind when 'compose_env' then 'ключ среды'
                       when 'compose_mount' then 'монтирование'
                       when 'compose_port' then 'порт' end as what,
             token as value, lines
      from code_refs where kind in ('compose_env', 'compose_mount', 'compose_port');

      -- Shell scripts: the commands called, the heredoc bodies and the
      -- DANGEROUS places. The latter are not a warning from the tool but a list
      -- for the eye: in this tree a recursive removal is worth knowing by name.
      create view v_sh_command as
      select path, token as command, detail->>'line' as line_text, lines, count
      from code_refs where kind = 'sh_command';

      create view v_sh_dangerous as
      select path, token as line_text, lines
      from code_refs where kind = 'sh_dangerous';

      -- A configuration key: a path in the yaml/json tree. There are no VALUES
      -- here and there cannot be — in a configuration file a value is a
      -- password, an address or a key.
      create view v_conf_key as
      select path, token as key, lines
      from code_refs where kind = 'conf_key';

      -- A migration exists in the tree but is not applied in an environment —
      -- and the other way round. The first is usually discovered halfway
      -- through a deploy, the second means the file was deleted or came from
      -- another branch.
      create view v_migration_drift as
      with sources as (select distinct source from db_migrations)
      select s.source,
             (select count(*) from db_migrations m
              where m.source = s.source and m.version ~ '^[0-9]{14}$')::int as applied,
             (select count(*) from db_migrations m
              where m.source = s.source and m.version !~ '^[0-9]{14}$')::int as legacy
      from sources s;

      -- Tables and columns that were TOUCHED in production. Proof of life
      -- stronger than any static one: the query did not "possibly run", it ran.
      -- `days` is in how many days of the window the table was seen. Without
      -- that number "touched in production" and "touched once in eleven days"
      -- are the same statement, while they are different things: the second
      -- looks like the remains of a mechanism.
      create view v_runtime_table as
      select t.name as table_name, r.place, sum(r.hits)::bigint as hits,
             count(distinct r.digest)::int as queries, max(r.day) as last_day,
             count(distinct r.day)::int as days
      from sql_runtime r cross join lateral unnest(r.tables) as t(name)
      group by 1, 2;

      -- The observation window: how many days of production logs lie in the
      -- index. Any "not touched in production" is unreadable without that
      -- number — not touched in a day and not touched in three months are
      -- different statements, and the first means almost nothing. So the window
      -- is printed next to every such answer.
      create view v_runtime_window as
      select min(day) as first_day, max(day) as last_day,
             count(distinct day)::int as days, count(distinct place)::int as places,
             count(distinct host)::int as hosts, count(*)::int as skeletons,
             sum(hits)::bigint as hits,
             count(*) filter (where not parsed)::int as unparsed
      from sql_runtime;

      -- `mode` tells "named in the selection" from "rows are filtered by it".
      -- The first means almost nothing: in production a query selects the whole
      -- field list.
      create view v_runtime_column as
      select c.name as column_name, r.place, sum(r.hits)::bigint as hits,
             count(distinct r.digest)::int as queries, max(r.day) as last_day,
             count(distinct r.day)::int as days,
             bool_or(c.name = any(r.writes)) as written,
             bool_or(c.name = any(r.filters)) as filtered
      from sql_runtime r
      cross join lateral unnest(r.columns || r.filters || r.writes) as c(name)
      group by 1, 2;

      -- The table worked in production, and NOT ONE parsed query in the code
      -- names it: either the name is assembled by interpolation (and then this
      -- is an answer to a blind spot), or something other than this application
      -- touches it.
      create view v_runtime_unknown_table as
      select rt.table_name, rt.place, rt.hits, rt.queries, rt.last_day
      from v_runtime_table rt
      where not exists (select 1 from code_refs c
                        where c.kind in ('pg_table', 'pg_table_guess') and c.token = rt.table_name);

      -- A fragment of a query, or human text that happens to start with a
      -- keyword. NOT a blind spot: there is no whole statement in the string,
      -- and there is nothing to be ignorant about. Before the split these
      -- records inflated the blind-spot count by more than a hundred.
      create view v_sql_piece as
      select path, token as text, detail->>'error' as error, lines, count
      from code_refs where kind = 'sql_piece';

      -- A blind spot at the COLUMN level: the code addresses `table.column`
      -- which that table lacks IN EVERY environment. For tables such an answer
      -- existed (`v_missing_table_usage`), for columns it did not; the very
      -- first check found two production queries that cannot run, plus two
      -- losses of precision in the parser itself (a qualified star, a subquery
      -- in `from`).
      --
      -- System columns are filtered out: `ctid` and `oid` are not listed in the
      -- catalogue yet exist on every table. A `$1` hole in a name is not a name.
      create view v_column_blind as
      select r.owner as table_name, r.token as column_name,
             case r.kind when 'pg_column_write' then 'запись' else 'чтение' end as mode,
             -- A near name on the same table: all five breakages found turned
             -- out to be off by one word (`last_added` against
             -- `added_at_time`, `creation_time` against `created_data`).
             -- Without the hint the report makes you search for what is already
             -- known.
             (select string_agg(n.column_name, ', ' order by n.column_name)
              from (select distinct column_name from v_columns where table_name = r.owner) n
              where n.column_name like left(r.token, greatest(length(r.token) / 2, 4)) || '%'
                 or r.token like left(n.column_name, greatest(length(n.column_name) / 2, 4)) || '%') as looks_like,
             r.path, r.lines, r.count,
             -- THE CLASS OF THE PLACE. In a spec a query is sometimes DATA: the
             -- subject of the spec is a failure or a quoting rule, and nobody
             -- executes such a query. In a probe script the same. Mixing them
             -- with production code is not allowed: there it is an error that
             -- runs every time, here it is text inside a test assertion.
             case
               when r.path like 'spec/%' then 'спека: запрос как данные'
               when r.path like 'script/%' or r.path like 'scripts/%' then 'скрипт'
               else 'БОЕВОЙ КОД'
             end as kind
      from code_refs r
      -- `exists`/`not exists` instead of a join against a `distinct`: with the
      -- join the planner took a nested loop over a non-materialised `distinct`
      -- and discarded 22 million rows — 2.9 s for the single question "how much
      -- of this is production". The same answer, but 0.2 s; the equality of the
      -- answers was checked with `except` in both directions.
      where r.kind in ('pg_column', 'pg_column_write')
        and r.owner <> ''
        and exists (select 1 from v_columns t where t.table_name = r.owner)
        and not exists (select 1 from v_columns c
                        where c.table_name = r.owner and c.column_name = r.token)
        and r.token <> all (array['ctid', 'oid', 'xmin', 'xmax', 'cmin', 'cmax', 'tableoid'])
        and position('$1' in r.token) = 0;

      -- Which table a field list belongs to. The share of matched names is the
      -- measure of confidence: a list from a configuration file is not labelled
      -- with a table, and it can only be linked by the composition of its names.
      create view v_list_table as
      select distinct on (path, name) path, name, table_name, matched, size,
             (100 * matched / greatest(size, 1))::int as share
      from (select l.path, l.name, c.table_name, l.size, count(distinct u.col)::int as matched
            from v_column_lists l
            cross join lateral unnest(l.columns) as u(col)
            join (select distinct table_name, column_name from v_columns) c
              on c.column_name = u.col
            group by 1, 2, 3, 4) q
      order by path, name, matched desc, table_name;

      -- Defects of the field lists themselves. Both checks are mechanical, and
      -- both catch what a human once found by eye: in one field list a name
      -- appears twice while its neighbour in the series does not appear at all —
      -- and a column is filled for tens of thousands of people while nothing
      -- reads it.
      -- Only lists confidently bound to a table: otherwise sets of words that
      -- matched column names by accident (`actions`, `texts`) crawl into the
      -- defects.
      create view v_column_list_defect as
      select 'повтор в списке' as kind, l.path, l.name as list_name,
             t.table_name, d.key as column_name, (d.value #>> '{}')::int as times
      from v_column_lists l
      join v_list_table t on t.path = l.path and t.name = l.name
                         and t.share >= 60 and t.matched >= 5
      cross join lateral jsonb_each(l.dups) as d(key, value)
      -- A purely numeric "name" is not a column but an element of an
      -- enumeration: there is a table with columns `1`…`33`, and without this
      -- filter it produced a hundred false rows. Single-character names come
      -- from the same place: a table with columns `a`…`t` matched any set of
      -- letters in the code.
      where d.key !~ '^[0-9]+$' and length(d.key) >= 3
      union all
      select 'пропуск в серии', t.path, t.name, t.table_name, c.column_name,
             (select count(*)::int from unnest(l.columns) as s(col)
              where regexp_replace(s.col, '[0-9]+$', '') = regexp_replace(c.column_name, '[0-9]+$', ''))
      from v_list_table t
      join v_column_lists l on l.path = t.path and l.name = t.name
      join (select distinct table_name, column_name from v_columns) c
        on c.table_name = t.table_name
      where t.share >= 60 and t.matched >= 5
        and c.column_name <> all (l.columns)
        and c.column_name ~ '[0-9]$'
        -- A series is `opt4_1…opt4_6`, not `1…33`: a numeric name has no prefix.
        and regexp_replace(c.column_name, '[0-9]+$', '') <> ''
        and (select count(*) from unnest(l.columns) as s(col)
             where regexp_replace(s.col, '[0-9]+$', '') = regexp_replace(c.column_name, '[0-9]+$', '')) >= 2;

      -- A hole in a query: what gets interpolated and into which position of
      -- the query. The parser substitutes `$1` for the hole, otherwise the SQL
      -- cannot be parsed — but the expression itself is no longer lost, and
      -- "where is a variable interpolated into an in (…)" became a query rather
      -- than a manual walk of the tree.
      -- `fragment` means the hole sits not in a whole query but in a fragment
      -- (`"user_id in (\#{sub})"`): there is neither select nor from nearby, and
      -- the human eye skips over such a place most easily of all.
      create view v_sql_holes as
      select path, token as root, owner as context,
             detail->>'expr' as expr, detail->>'scope' as scope,
             -- The same hole occurs in several methods of a file; the row is
             -- one while the methods differ, and all of them have to be shown.
             array_to_string(array[detail->>'scope'] ||
                             coalesce(array(select jsonb_array_elements_text(detail->'scopes')), '{}'),
                             ', ') as scopes,
             coalesce((detail->>'blind')::boolean, false) as blind,
             coalesce((detail->>'fragment')::boolean, false) as fragment,
             detail->>'carrier' as carrier, detail->>'call' as call,
             detail->>'const' as const, detail->>'sql' as sql,
             count, lines
      from code_refs where kind = 'sql_hole';

      -- The column is named in a list — and, if the same list is substituted
      -- into a query, WHERE it lands there: `select_list` is a read, `set` is a
      -- write, anything else is an untraced direction. A local name is looked up
      -- within its own file, a CONSTANT across the whole tree: that is exactly
      -- how a list from a configuration file gets linked to a selection in
      -- another file.
      create view v_column_via_list as
      select l.path as list_path, l.name as list_name, l.scope, c.column_name,
             h.context, h.path as hole_path,
             case h.context when 'select_list' then 'чтение'
                            when 'set' then 'запись'
                            when null then 'подстановка не найдена'
                            else 'направление не прослежено' end as direction
      from v_column_lists l
      cross join lateral unnest(l.columns) as c(column_name)
      left join v_sql_holes h
        on h.root = l.name and (h.path = l.path or l.name ~ '^[A-Z]');

      -- Assignments. Not all of them: only those carrying a query, those
      -- substituted into a hole, and those visible beyond the file boundary (@,
      -- @@, $, a constant).
      create view v_assigns as
      select path, token as name, owner as scope, detail->>'value' as value,
             coalesce((detail->>'sql')::boolean, false) as is_sql,
             coalesce((detail->>'part')::boolean, false) as is_part,
             coalesce((detail->>'carrier')::boolean, false) as carrier,
             detail->>'op' as op, detail->>'from' as from_call, detail->>'const' as from_const,
             detail->'more' as more, count, lines
      from code_refs where kind = 'assign';

      -- Method declarations. Two different properties, and they must not be
      -- confused:
      --   has_sql      — the method body contains a query (true for almost every
      --                  model);
      --   returns_sql  — the method RETURNS a whole statement;
      --   returns_part — it returns a fragment (`(user_id in (select …))`).
      -- For a hole there is no difference between the last two: a piece of a
      -- query will be substituted.
      create view v_defs as
      select path, token as method, nullif(owner, '') as class_name,
             coalesce((detail->>'sql')::boolean, false) as has_sql,
             coalesce((detail->>'returns')::boolean, false) as returns_sql,
             coalesce((detail->>'returns_part')::boolean, false) as returns_part,
             coalesce((detail->>'singleton')::boolean, false) as singleton,
             coalesce(detail->>'visibility', 'public') as visibility,
             coalesce(array(select jsonb_array_elements_text(detail->'params')), '{}') as params,
             -- The length of the method in lines, counted during the parse. Zero
             -- means "this index row is older than the rule" — the report has to
             -- tell that from a one-line method.
             coalesce((detail->>'size')::int, 0) as size,
             count, lines
      from code_refs where kind = 'def';

      -- Where the text in a hole comes from. Three routes, and all three are
      -- CANDIDATES rather than proofs:
      --   assign      — something was assigned to the same name;
      --   def         — that is the name of a method (`\#{where_sql}`);
      --   assign->def — assigned from a call (`cond = build_cond`), and this is
      --                 that method.
      --
      -- A match on a name alone is exactly the trap that makes a text search
      -- useless: the tree holds a dozen `delete` methods and not one of them has
      -- anything to do with somebody else's hole. So every link carries its
      -- strength:
      --   file  — the source is in the same file as the hole;
      --   class — in the same class (an ivar of a controller seen in a view will
      --           not land here: the class is different there);
      --   name  — only the name matched. Look at it last and do not trust it
      --           without eyes.
      -- A local variable is looked up only within its own file: local `sql`
      -- variables from different files are not related to each other in any way.
      create view v_sql_hole_source as
      with h as (
        select *, nullif(regexp_replace(scope, '[#.][^#.]*$', ''), '') as class_name
        from v_sql_holes
      ),
      d as (
        select *, (returns_sql or returns_part) as gives_sql,
               case when returns_sql then 'запрос' when returns_part then 'обрывок' else '' end as form
        from v_defs
      )
      select h.path, h.root, h.context, h.expr, h.scope, h.sql, h.lines as hole_lines,
             'assign' as source_kind, a.path as source_path, a.scope as source_scope,
             a.value as source_value, (a.is_sql or a.is_part) as source_is_sql,
             case when a.is_sql then 'запрос' when a.is_part then 'обрывок' else '' end as source_form,
             a.lines as source_lines,
             case when a.path = h.path then 'файл'
                  when regexp_replace(a.scope, '[#.][^#.]*$', '') = h.class_name then 'класс'
                  else 'имя' end as match
      from h
      join v_assigns a
        on a.name = h.root
       and (a.path = h.path or h.root ~ '^[@$]' or h.root ~ '^[A-Z]')
      union all
      -- A method with the same name. `h.call` is for `ReportSql.new.take_all`:
      -- the root there is a constant, and the carrier is its method.
      select h.path, h.root, h.context, h.expr, h.scope, h.sql, h.lines,
             'def', d.path, coalesce(d.class_name, ''), '', d.gives_sql, d.form, d.lines,
             case when d.path = h.path then 'файл'
                  when d.class_name = h.class_name then 'класс'
                  when h.const is not null and d.path = c.path then 'класс'
                  else 'имя' end
      from h
      left join app_constants c on c.constant = h.const
      join d on d.method = coalesce(h.call, h.root)
      union all
      select h.path, h.root, h.context, h.expr, h.scope, h.sql, h.lines,
             'assign->def', d.path, coalesce(d.class_name, ''), a.value, d.gives_sql, d.form, d.lines,
             case when d.path = h.path then 'файл'
                  when d.class_name = h.class_name then 'класс'
                  when a.from_const is not null and d.path = c.path then 'класс'
                  else 'имя' end
      from h
      join v_assigns a on a.name = h.root and a.path = h.path and a.from_call is not null
      left join app_constants c on c.constant = a.from_const
      join d on d.method = a.from_call;

      -- What all this is for: what arrives in the hole is not a value but an
      -- assembled query. The name standing in the hole had text with a select
      -- assigned to it somewhere — or that is the name of the method that
      -- assembles the query. The meaning of such a query is set by a line other
      -- than the one it is written in, and a text search does not find it.
      create view v_sql_hole_carries_sql as
      select distinct path, root, context, expr, scope, sql, hole_lines,
             source_kind, source_path, source_scope, source_value, source_form, match
      from v_sql_hole_source where source_is_sql;

      -- A hole whose source was not found while its root is a parameter of the
      -- method it sits in: the text comes from the caller. A separate kind, so
      -- that the report says "the source is at the caller" instead of staying
      -- silent.
      create view v_sql_hole_from_param as
      select h.path, h.root, h.context, h.expr, h.scope, h.lines, d.method, d.params
      from v_sql_holes h
      join v_defs d
        on d.path = h.path
       and h.scope = coalesce(d.class_name, '') || case when d.singleton then '.' else '#' end || d.method
       and h.root = any(d.params);

      -- The main thing all of this is for: the code addresses a table that some
      -- source does not have. In that data centre this query will fail, and from
      -- the code that is not visible.
      create view v_missing_table_usage as
      select r.token as table_name, tp.missing_in,
             count(distinct r.path)::int as files,
             array_agg(distinct r.kind) as kinds,
             (array_agg(distinct r.path))[1:5] as sample
      from code_refs r
      join v_table_presence tp on tp.name = r.token
      where r.kind in ('pg_table', 'pg_table_guess') and cardinality(tp.missing_in) > 0
      group by r.token, tp.missing_in;

      -- The code addresses a table that exists NOWHERE: a typo or dead code.
      create view v_unknown_table_usage as
      select r.token as table_name,
             count(distinct r.path)::int as files,
             (array_agg(distinct r.path))[1:5] as sample
      from code_refs r
      left join v_table_presence tp on tp.name = r.token
      where r.kind = 'pg_table' and tp.name is null
        and r.token not like 'pg\\_%'
      group by r.token;

      -- Table -> the models sitting on it.
      create view v_table_models as
      select table_name, array_agg(class_name order by class_name) as models,
             array_agg(distinct path) as paths
      from app_models where table_name is not null group by table_name;

      -- Route -> the controller file that serves it.
      -- Edges of the graph. A reference to a constant is only one sort of them,
      -- and on its own it left all 3,902 views and the model associations
      -- outside the graph.
      create view v_const_edges as
      select r.path as from_path, r.owner as scope, c.path as to_path, 'const' as kind
      from code_refs r
      join app_constants c on c.constant = r.token
      where r.kind = 'const_ref' and c.path <> r.path;

      -- `render 'searchedit/sex_with_gal'` leads into ALL interface modes at
      -- once: their logical name is shared while the files differ. The suffix is
      -- compared with right() rather than LIKE: view names are full of
      -- underscores, and for LIKE an underscore is a wildcard.
      -- The join condition here is one, but it is written in two tiers, and that
      -- is for SPEED. The original `v.token = r.token or right(v.token,
      -- length(r.token)+1) = '/' || r.token` cannot be served by an index at
      -- all: the planner went with a nested loop, discarded 4.8 million pairs
      -- and spent 1.4 s on this view. And `v_code_edges` goes through it, and
      -- the recursive walk of `v_reach` goes through that: `bin/xref callers`
      -- answered in 26 seconds, which means the tool was not used.
      --
      -- The first tier is THE LAST SEGMENT of the name on both sides: if a full
      -- view name ends with `/` plus the one being looked for, their last
      -- segments are necessarily equal. That join can be hashed. The second tier
      -- is the original condition in full, now as a filter: the first tier is
      -- only NECESSARY, and sufficiency is checked by this one. The answer is
      -- the same, the price is not.
      create view v_render_edges as
      select r.path as from_path, '' as scope, v.path as to_path, 'render' as kind
      from code_refs r
      join code_refs v
        on v.kind = 'view_name'
       and regexp_replace(v.token, '^.*/', '') = regexp_replace(r.token, '^.*/', '')
       and (v.token = r.token
            or right(v.token, length(r.token) + 1) = '/' || r.token)
      where r.kind = 'render_ref' and v.path <> r.path;

      -- A CANDIDATE edge rather than a fact. `render
      -- :partial=>"theme_old/layouts/\#{p}"` does not name a view: the name is
      -- finished at runtime. The literal pieces are there, though, and a pattern
      -- `theme_old/layouts/*` is assembled from them — and through the pattern it
      -- is visible WHERE this call can go. Previously such a call yielded
      -- neither an edge nor a mark of ignorance: the site's production menu was
      -- listed as unreachable.
      --
      -- Escaping with a tilde rather than a backslash: view names are full of
      -- underscores, and for LIKE an underscore is a wildcard.
      create view v_render_candidate_edges as
      select r.path as from_path, '' as scope, v.path as to_path, 'render?' as kind
      from code_refs r
      join code_refs v
        on v.kind = 'view_name'
       and (v.token like (r.detail->>'glob') escape '~'
            or v.token like ('%/' || (r.detail->>'glob')) escape '~')
      where r.kind = 'render_dynamic' and r.owner = 'skeleton'
        and r.detail->>'glob' is not null and v.path <> r.path;

      -- A render whose view name sits entirely in a variable: there is no
      -- pattern, and there can be no candidates. A separate kind, so that the
      -- report says it out loud instead of hiding it behind silence.
      create view v_render_blind as
      select path, token, count, lines, detail->>'source' as source
      from code_refs where kind = 'render_dynamic' and owner <> 'skeleton';

      -- An association is an edge too: has_many :photos leads to Photo.
      create view v_assoc_edges as
      select mf.path as from_path, '' as scope, tf.path as to_path, 'assoc' as kind
      from app_associations a
      join app_constants mf on mf.constant = a.class_name
      join app_constants tf on tf.constant = a.target
      where a.target is not null and tf.path <> mf.path;

      -- A controller renders a view BY THE NAME OF THE ACTION, with no `render`
      -- at all. Without this edge the views hung as a separate island: only a
      -- neighbouring partial reached `_sex_with_gal`, and there were no entry
      -- points whatsoever.
      create view v_action_view_edges as
      select c.path as from_path, '' as scope, v.path as to_path, 'action' as kind
      from app_routes r
      join app_controllers c on c.class_name = r.controller_class and c.path is not null
      -- Two tiers for the same reason as in v_render_edges: the original
      -- condition through `right()` cannot be hashed, and the view was computed
      -- with a nested loop. The first tier is the last segment of the view name
      -- against the action; it is necessary, and sufficiency is checked by the
      -- second.
      join code_refs v
        on v.kind = 'view_name'
       and regexp_replace(v.token, '^.*/', '') = r.action
       and (v.token = r.controller || '/' || r.action
            or right(v.token, length(r.controller) + length(r.action) + 2)
               = '/' || r.controller || '/' || r.action)
      where r.controller <> '' and r.action <> '';

      create view v_code_edges as
      select from_path, scope, to_path, kind from v_action_view_edges
      union all
      select from_path, scope, to_path, kind from v_const_edges
      union all
      select from_path, scope, to_path, kind from v_render_edges
      union all
      select from_path, scope, to_path, kind from v_render_candidate_edges
      union all
      select from_path, scope, to_path, kind from v_assoc_edges
      union all
      select from_path, scope, to_path, kind from v_js_edges;

      -- Entry points: where the code starts executing at all, and where.
      -- WHERE THE CODE RUNS, WITH A FALLBACK. Reachability is counted per place,
      -- and the places come from the live service inventory — which a project
      -- without ssh to anything simply does not have. Then the cross join below
      -- yielded NOTHING, every entry point disappeared and the report said
      -- "reachable from an entry point: 0" about a tree where the graph was
      -- perfectly fine. Measured in a project on esbuild on 2026-10-10: 19
      -- JavaScript files, 11 import edges, zero reachable. One synthetic place
      -- keeps the whole layer working, and the audit says the places are not
      -- configured instead of printing zeros.
      create view v_places as
      select distinct place from run_units
      union
      select 'local' where not exists (select 1 from run_units);

      create view v_entry_points as
      select c.path, p.place, 'controller' as kind, c.class_name as entry
      from app_controllers c
      join app_routes r on r.controller_class = c.class_name
      cross join v_places p
      where c.path is not null
      group by c.path, p.place, c.class_name
      union all
      select j.path, rp.place, 'job', j.class_name
      from app_jobs j
      cross join lateral unnest(j.places) as d(v)
      join run_places rp on rp.env_id = d.v or d.v = '*'
      where j.path is not null
      union all
      -- The same fallback for jobs: with no environments described, a scheduled
      -- job is still an entry point — in the only place there is.
      select j.path, p.place, 'job', j.class_name
      from app_jobs j
      cross join v_places p
      where j.path is not null and not exists (select 1 from run_places)
      union all
      -- WebSocket channels: the service is up in every data centre, yet they
      -- were not entry points — all the code reachable only from a channel lay
      -- outside the graph.
      select c.path, u.place, 'channel', c.constant
      from app_constants c
      join run_units u on u.unit = any (#{Xref.sql_text_array(Xref.idioms[:channel_service_units])})
      where c.path like 'app/channels/%'
      union all
      -- JavaScript build roots. These are ENTRY POINTS rather than dead files:
      -- nothing imports them by construction — the bundler starts from them.
      -- While they were not named as entry points the whole of JavaScript lay
      -- outside the graph, and all 16 roots were listed as unreachable.
      --
      -- THE ROOTS COME FROM THE FACTS FIRST: `js_entry` is what the bundler's
      -- own config names, and the index already parses it. The patterns are the
      -- fallback for a tree whose config cannot be read, and they are a SETTING
      -- (`idioms.js_entry_paths`) — baked in as one Webpacker layout they made
      -- the whole front end of a project on esbuild unreachable: nineteen files,
      -- eleven import edges, zero reachable. Reported from that project.
      select f.path, p.place, 'pack', regexp_replace(f.path, '.*/', '')
      from code_files f
      cross join v_places p
      where f.lang = 'js'
        and (exists (select 1 from code_refs e where e.kind = 'js_entry' and e.token = f.path)
             or f.path like any (#{Xref.sql_text_array(Xref.idioms[:js_entry_paths])}));

      -- Robots: service -> rake task -> the file where that task is declared.
      create view v_entry_rake as
      select cr.path, u.place, u.rake_task as scope, u.unit
      from run_units u
      join code_refs cr on cr.kind = 'rake_entry' and cr.token = u.rake_task
      where u.rake_task is not null;

      -- Reachability: which files each place reaches.
      --
      -- It errs IN BOTH DIRECTIONS, and that has to be remembered:
      --   too wide — a reference to a constant is not yet a call, and a
      --              conditional branch is indistinguishable from an
      --              unconditional one;
      --   too deep — edges are visible only through constants; a call on an
      --              object (`user.photos.each`) is invisible to the graph, as
      --              are eval and send.
      -- So landing here means "looks reachable", while NOT landing here does not
      -- mean "does not run". This is a shortlist for review, not a proof.
      create view v_reach as
      with recursive seed as (
        select path, place from v_entry_points
        union
        select path, place from v_entry_rake
        union
        select e.to_path, s.place
        from v_entry_rake s
        join v_code_edges e on e.from_path = s.path and e.scope = s.scope
      ),
      walk (path, place, depth) as (
        select path, place, 0 from seed
        union
        select e.to_path, w.place, w.depth + 1
        from walk w
        join v_code_edges e on e.from_path = w.path and e.scope = ''
        where w.depth < 9
      )
      select path, place, min(depth) as depth
      from walk group by path, place;

      -- What all of it is for: the code addresses a table that is missing in
      -- this place, AND this place is reached by the code. A shortlist for
      -- review: a row from here has to be checked by eye, but there are a
      -- handful of them rather than hundreds.
      create view v_break_here as
      select r.token as table_name, rc.place, r.path, r.kind, rc.depth,
             array_to_string(r.lines, ',') as lines
      from code_refs r
      join v_table_presence tp on tp.name = r.token
      join v_reach rc on rc.path = r.path
      where r.kind in ('pg_table', 'pg_table_guess')
        and rc.place = any(tp.missing_in);

      -- jsonb keys the code mentions (from parsed SQL).
      create view v_json_key_usage as
      select split_part(owner, '.', 1) as table_name,
             split_part(owner, '.', 2) as column_name,
             token as key, path, count, lines
      from code_refs where kind = 'json_key';

      -- The code reads a key never met in the data — and the other way round.
      -- The first is more often a typo or a rename, the second is simply
      -- unused. Keys are consolidated across every source asked: met in at
      -- least one means it exists in the data. Otherwise one empty data centre
      -- would produce a finding out of nothing.
      create view v_json_key_gap as
      select coalesce(u.table_name, k.table_name) as table_name,
             coalesce(u.column_name, k.column_name) as column_name,
             coalesce(u.key, k.key) as key,
             u.path as used_in, k.hits, k.sources
      from (select distinct table_name, column_name, key, path from v_json_key_usage) u
      full join (
        select table_name, column_name, key, sum(hits) as hits,
               array_agg(distinct source) as sources
        from json_keys group by table_name, column_name, key
      ) k
        on k.table_name = u.table_name and k.column_name = u.column_name and k.key = u.key
      where u.key is null or k.key is null;

      -- The action was requested at least once: proof of life for a route.
      -- Unlike v_view_used this also includes the ones that render nothing.
      create view v_action_used as
      select action, sum(hits)::bigint as hits, count(distinct day)::int as days,
             array_agg(distinct place order by place) as places,
             min(day) as first_day, max(day) as last_day
      from action_runtime group by action;

      -- The view was rendered at least once: a proof rather than an estimate.
      create view v_view_used as
      select path, sum(hits)::bigint as hits,
             count(distinct action)::int as actions,
             array_agg(distinct place order by place) as places
      from view_runtime where path is not null group by path;

      -- Who actually renders it: the controller action from the same request.
      create view v_view_actions as
      select path, action, sum(hits)::bigint as hits,
             array_agg(distinct place order by place) as places
      from view_runtime where path is not null and action <> '' group by path, action;

      -- The view file exists, and the logs never contained it.
      create view v_view_dead as
      select f.path
      from code_files f
      left join v_view_used u on u.path = f.path
      where f.path like 'app/views/%' and u.path is null;

      create view v_route_code as
      select r.verb, r.path, r.controller, r.action, r.route_name,
             r.controller_class, c.path as controller_path
      from app_routes r
      left join app_controllers c on c.class_name = r.controller_class;

      -- TOP-LEVEL FUNCTIONS in JavaScript and their call sites. Class methods
      -- were known to the index, these were not: there are about five hundred of
      -- them, and half the code could not answer the question "who calls this".
      create view v_js_func as
      select path, token as name, nullif(owner, '') as scope, lines
      from code_refs where kind = 'js_func';

      -- A hook rather than a fact: a name is a poor key (as in Ruby). The report
      -- is obliged to say so, otherwise "there is a call" gets read as "this
      -- very call".
      create view v_js_call as
      select path, token as name, lines from code_refs where kind = 'js_call';

      -- A function nothing calls. The classes are needed: an exported one may be
      -- called by another file (visible through the imports), while a function
      -- in a file no import reaches is unnecessary together with that file.
      create view v_js_func_unused as
      select f.path, f.name, f.scope,
             exists (select 1 from code_refs e
                     where e.kind = 'js_export' and e.path = f.path and e.token = f.name) as exported,
             (select u.kind from v_js_unreachable u where u.path = f.path) as file_kind
      from v_js_func f
      where not exists (select 1 from v_js_call c where c.name = f.name);

      -- LIBRARIES: are they still called. There is no point going inside a
      -- library — "unused" is the majority in there by construction, and one
      -- throws a library out by version rather than by rule. But its CALLS are a
      -- legitimate question: a package whose binding is mentioned nowhere leaves
      -- the bundle entirely.
      create view v_js_package_use as
      select b.owner as package,
             count(distinct b.path)::int as files,
             array_agg(distinct b.token order by b.token) as bindings,
             sum((b.detail->>'mentions')::int)::int as mentions
      from code_refs b where b.kind = 'js_binding' and b.owner <> ''
      group by 1;

      -- STYLESHEETS. The layer was added on 2026-10-10; before that 43 of our
      -- own files, 22 thousand lines, were invisible to the index.
      create view v_css_file as
      select f.path, f.bytes,
             (select count(*) from code_refs c where c.kind = 'css_class' and c.path = f.path)::int as classes,
             (select count(*) from code_refs i where i.kind = 'css_import' and i.path = f.path)::int as imports
      from code_files f where f.lang = 'css';

      -- An inclusion edge: an `@import` inside the styles, resolved to a path.
      -- It enters v_code_edges, so reachability stops breaking off at the styles.
      create view v_css_edges as
      select path as from_path, '' as scope, token as to_path, 'css_import' as kind
      from code_refs where kind = 'css_import';

      -- NOTHING includes this stylesheet. The classes are mandatory: a build
      -- entry point and a file mentioned by a template through a path are alive
      -- by construction.
      --
      -- `assembled from parts` is a separate class with a separate reason: in a
      -- build config the path is written as `path.join(root, 'app', …)`, it
      -- exists nowhere as a whole string, and a string search declared such a
      -- file dead (verified by hand on `pages_tw.css`).
      create view v_css_unreachable as
      select f.path, f.bytes, f.classes,
             case
               when f.path like '%/vendor/%' or f.path like 'vendor/%'
                 or f.path like 'node_modules/%' then 'поставляемое'
               when f.path like 'public/%' then 'отдаётся как файл'
               when exists (select 1 from code_refs e where e.kind = 'js_entry' and e.token = f.path)
                 then 'вход сборки'
               when exists (select 1 from v_css_edges e where e.to_path = f.path) then 'подключён @import'
               -- A stylesheet is also pulled in by JAVASCRIPT: `import
               -- '../css/uppy_upload.css'` in a pack root, and the bundler emits
               -- the css as a side output. Without this branch a live file
               -- landed among the removal candidates (caught on
               -- `uppy_upload.css` before the answer was published).
               when exists (select 1 from code_refs j
                            where j.kind = 'js_import' and j.token = f.path) then 'подключён из javascript'
               when exists (select 1 from code_refs r where r.kind = 'asset_ref' and r.token = f.path)
                 then 'упомянут в шаблоне'
               else 'КАНДИДАТ НА СНЯТИЕ'
             end as kind
      from v_css_file f;

      -- Pack → build entry point. The key of the `entryPoints` object is THE
      -- PACK NAME, which is what a page asks the styles by
      -- (`modern_stylesheet_pack_tag 'theme_new'`).
      create view v_pack_entry as
      select detail->>'pack' as pack, token as entry, path as config, 'ключ конфига' as how
      from code_refs where kind = 'js_entry' and detail->>'pack' is not null
      union
      -- BY A NAMING CONVENTION, and that is said out loud: an entry assembled in
      -- the config from parts
      -- (`path.join(root,'app','javascript','theme_new','theme_new.css')`) has no
      -- key at all, while a template asks for the pack by the name `theme_new`.
      -- The pack name coincides with the entry file name without its extension —
      -- that is what links them.
      -- Without this a contour turned out to have NOT ONE stylesheet of its own,
      -- and the view answered "no rule in this contour" to all 632 classes —
      -- honestly but uselessly.
      select r.token as pack, e.token as entry, e.path as config, 'по имени файла' as how
      from code_refs e
      join code_refs r on r.kind = 'pack_ref'
                     and r.token = regexp_replace(regexp_replace(e.token, '.*/', ''), '\.[a-z]+$', '')
      where e.kind = 'js_entry' and e.detail->>'pack' is null;

      -- Pack → every stylesheet file it pulls in (the entry plus the transitive
      -- closure of @import).
      create view v_pack_css as
      with recursive reach as (
        select e.pack, e.entry as path from v_pack_entry e
        union
        select r.pack, d.to_path from reach r join v_css_edges d on d.from_path = r.path
      )
      select pack, path from reach
      where exists (select 1 from code_files f where f.path = reach.path and f.lang = 'css');

      -- Who names a pack and which contour it belongs to. A contour is the top
      -- directory of a template, and for a layout it is the layout's own name:
      -- `layouts/theme_new.html.erb` is the contour `theme_new`. The rule is
      -- mechanical and explainable.
      create view v_pack_ref as
      select r.path, r.token as pack,
             case
               when r.path like 'app/views/layouts/%'
                 -- `split_part` instead of a regexp deliberately: a backslash in
                 -- the pattern did not survive two layers of quoting on its way
                 -- into SQL, and the contour name came out EMPTY — the view
                 -- silently returned zero rows.
                 then split_part(regexp_replace(r.path, '.*/', ''), '.', 1)
               when r.path like 'app/views/%'
                 then split_part(regexp_replace(r.path, '^app/views/', ''), '/', 1)
               else 'вне шаблонов'
             end as contour
      from code_refs r where r.kind = 'pack_ref';

      -- A class declared in the styles. One row per name and file.
      create view v_css_class as
      select c.path, c.token as name, c.lines,
             (select kind from v_css_unreachable u where u.path = c.path) as file_kind
      from code_refs c where c.kind = 'css_class';

      -- The class IS MENTIONED: as a literal in the markup, from code at
      -- runtime, or the stylesheet itself pulls it in through `@apply`. Three
      -- routes, and without any one of them a declared class looks unnecessary.
      create view v_css_class_use as
      select token as name, 'разметка' as how, path, lines from code_refs where kind = 'html_class'
      union all
      select token as name, '@apply' as how, path, lines from code_refs where kind = 'css_apply';

      -- A class pattern from the markup (`btn-$1`): not an answer, but not
      -- ignorance either — a declared class is findable through it.
      create view v_css_class_pattern as
      select token as pattern, detail->>'glob' as glob, path, lines
      from code_refs where kind = 'html_class_pattern' and detail->>'glob' is not null;

      -- THE MAIN QUESTION OF THIS LAYER, and its answer has classes rather than
      -- a yes/no.
      create view v_css_class_usage as
      select c.name, min(c.path) as declared_in, count(distinct c.path)::int as files,
             case
               when exists (select 1 from v_css_class_use u where u.name = c.name) then 'поминают'
               when exists (select 1 from v_css_class_pattern p
                            where c.name like p.glob escape '~') then 'подходит под узор'
               when min(c.file_kind) = 'КАНДИДАТ НА СНЯТИЕ' then 'файл никто не подключает'
               when min(c.file_kind) = 'поставляемое' then 'поставляемый стиль'
               else 'НЕ ПОМИНАЕТ НИКТО'
             end as verdict
      from v_css_class c group by c.name;

      -- IS THERE A RULE FOR THIS CLASS IN THIS CONTOUR. The question is not "is
      -- the class dead" but "does it do anything here": in the tree this is
      -- already being decided by hand — a comment in
      -- `theme_new/user/about_me.html.erb:312` explains that `check_ab` does
      -- nothing there, because `desktop/css3.css` is not included in that
      -- contour. It is answered mechanically where the pack is matched to a
      -- build entry; where it is not matched, the view says so.
      create view v_css_class_contour as
      with contour_pack as (
        -- A CONTOUR is only one whose chain is provable: the layout names the
        -- pack by its own name. `app/views/user/…` is not a contour (it has no
        -- layout of its own and is rendered under whichever one is chosen at
        -- runtime), and attributing styles to it means answering with an
        -- untruth. My first version invented five such "contours".
        select contour, pack from v_pack_ref where path like 'app/views/layouts/%'
      ),
      contour_css as (
        select distinct cp.contour, c.path
        from contour_pack cp join v_pack_css c on c.pack = cp.pack
      ),
      used as (
        select split_part(regexp_replace(r.path, '^app/views/', ''), '/', 1) as contour,
               r.token as name, r.path
        from code_refs r
        where r.kind = 'html_class' and r.path like 'app/views/%'
      )
      select u.contour, u.name, count(distinct u.path)::int as templates,
             case
               when exists (select 1 from contour_css cc join v_css_class d on d.path = cc.path
                            where cc.contour = u.contour and d.name = u.name) then 'правило в контуре есть'
               when not exists (select 1 from contour_css cc where cc.contour = u.contour)
                 then 'паки контура не сопоставлены входам'
               when exists (select 1 from v_css_class d where d.name = u.name)
                 then 'правило есть, но в другом контуре'
               else 'правила нет ни в одном НАШЕМ стиле'
             end as verdict
      from used u
      where u.contour in (select contour from contour_pack)
      group by u.contour, u.name;

      -- An assembled class with no pattern at all: the honest blind spot of
      -- this layer, and it has to be printed next to every answer of the form
      -- "the class is not needed".
      create view v_css_blind as
      select path, token as expr, lines from code_refs where kind = 'html_class_dynamic';

      -- An assembled translation key against THE STORE. The largest named blind
      -- spot (420 accesses, 137 distinct patterns) was not entirely blind: the
      -- pattern `user_notifs.L$1` is not "something unknown" but "one of
      -- user_notifs.Lmen, user_notifs.Lwomen", and the store knows that.
      --
      -- The prefix and the suffix are taken AROUND the hole rather than by
      -- gluing the piece before to the piece after: for
      -- `pitest.scales.scale_$1.expl.$1` the gluing yields
      -- `pitest.scales.scale.expl.`, which does not exist in the store at all —
      -- that is how I measured myself 36 patterns "without a match" instead of
      -- one.
      --
      -- The comparison goes through `starts_with` rather than `like prefix ||
      -- '%'`: key names are full of underscores, and in LIKE an underscore is a
      -- wildcard, so `payments.subscr_%` would also match
      -- `payments.subscrXxx`.
      create view v_i18n_pattern as
      -- `materialized` here is not decoration: without it the set of keys is
      -- recomputed FOR EVERY pattern (139 times over a hundred thousand rows),
      -- and `bin/xref texts` grew from 7 to 63 seconds — I introduced that
      -- myself. With one pass the same answers cost 0.3 s; the equality was
      -- checked with `except` in both directions.
      with keys as materialized (select distinct key from locale_keys),
      pattern as (
        select token,
               split_part(token, '$1', 1) as prefix,
               case when token like '%$1' then ''
                    else reverse(split_part(reverse(token), '1$', 1)) end as suffix,
               count(distinct path)::int as files,
               array_agg(distinct path order by path) as paths
        from code_refs where kind = 'i18n_dynamic' group by 1, 2, 3
      ),
      counted as (
        select p.token, p.prefix, p.suffix, p.files, p.paths,
               count(k.key)::int as keys,
               (array_agg(k.key order by k.key))[1:20] as sample
        from pattern p
        left join keys k
          on starts_with(k.key, p.prefix)
         and (p.suffix = '' or right(k.key, length(p.suffix)) = p.suffix)
        group by 1, 2, 3, 4, 5
      )
      select token as pattern, prefix, suffix, files, paths, keys,
             case
               -- A prefix shorter than four characters matches anything and
               -- explains everything at once, that is, nothing.
               when length(prefix) < 4 then 'приставка слишком короткая'
               when keys = 0 then 'НИ ОДНОГО КЛЮЧА'
               when keys <= 20 then 'один из ' || keys
               else 'широкий: ' || keys
             end as verdict,
             case when length(prefix) >= 4 and keys between 1 and 20
                  then array_to_string(sample, ', ') end as key_list
      from counted;

      -- A verdict together with its FRESHNESS. The state is computed here and
      -- only here: a verdict anchored to a file lives exactly until that file is
      -- edited, and repeating that rule in a second place would let the two
      -- drift apart.
      create view v_finding_verdict as
      select v.kind, v.subject, v.verdict, v.checked, v.reason, v.path,
             v.checked_at, v.git_sha,
             case
               when v.path is null then 'без файла'
               when f.path is null then 'файла нет'
               when f.sha = v.file_sha then 'свежий'
               else 'устарел'
             end as state
      from finding_verdicts v
      left join code_files f on f.path = v.path;

      -- What gets filtered out of the reports. Only "false", and only while the
      -- verdict is fresh: a stale one hides nothing, otherwise an edit to the
      -- file would silently bury a real problem that appeared in the place of
      -- the one verified as false.
      create view v_finding_hidden as
      select kind, subject, reason, checked, checked_at
      from v_finding_verdict
      where verdict = 'ложная' and state <> 'устарел';

      -- The reliability of a class: how much to trust a NEW finding of this
      -- kind. The numbers are printed next to the class in every report — before
      -- the journal no such number existed anywhere, and every finding read as
      -- equally weighty.
      create view v_finding_reliability as
      select kind,
             count(*)::int as checked,
             count(*) filter (where verdict = 'ложная')::int as wrong,
             count(*) filter (where verdict = 'настоящая')::int as genuine,
             (100 * count(*) filter (where verdict = 'ложная') / greatest(count(*), 1))::int as wrong_share,
             count(*) filter (where state = 'устарел')::int as stale,
             count(*) filter (where state = 'без файла')::int as timeless,
             max(checked_at) as last_checked
      from v_finding_verdict group by kind;
    SQL

    class << self
      def conn
        establish! unless @established
        Record.connection
      end

      def establish!
        Record.establish_connection(store_config)
        Record.connection.select_value('select 1')
        @established = true
      rescue ActiveRecord::NoDatabaseError
        create_store_database!
        Record.establish_connection(store_config)
        Record.connection.select_value('select 1')
        @established = true
      end

      # The query cache is switched off the same way as in database.yml: the
      # index has its own pool, it is not covered by `default:`, and the
      # executor hook lets a pool through only when `db_config.query_cache ==
      # false` (activerecord 8.1.3, query_cache.rb).
      # Measured before the fix: two consecutive `clock_timestamp()` calls
      # returned one value.
      # A bare URL carries no settings — it is parsed into a hash.
      def store_config
        ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver
          .new(Xref.store_url).to_hash
          .merge(query_cache: ENV.fetch('DB_QUERY_CACHE', 'off') == 'on')
      rescue StandardError
        Xref.store_url
      end

      # The DDL runs on EVERY command (`create table if not exists`, the views),
      # and two commands started at once deadlock on it: on 2026-09-03 four
      # parallel `bin/xref` runs produced `PG::TRDeadlockDetected` on an
      # AccessExclusiveLock. They are let through to the DDL one at a time —
      # there is nothing to wait for here, the schema is already in place, and
      # the second process passes straight through in milliseconds.
      DDL_LOCK_KEY = 8_074_311_020_260_903

      def migrate!
        c = conn
        c.execute("select pg_advisory_lock(#{DDL_LOCK_KEY})")
        begin
          drop_views!(c)
          c.execute(DDL)
        ensure
          c.execute("select pg_advisory_unlock(#{DDL_LOCK_KEY})")
        end
      end

      # Dropping all the views BY THE CATALOGUE rather than by a list of names
      # in the code.
      #
      # The list was maintained by hand, and that was enough to bring the tool
      # down: the new view `v_search_blind` did not make it into the list, and
      # the next run died with `relation already exists` in the middle of a
      # parse (2026-10-10). The catalogue forgets nothing — and incidentally
      # removes views left over from earlier versions of the tool that the code
      # has not held for a long time.
      #
      # `cascade` is safe here: this database holds nothing but our tables and
      # our views, and views depend only on each other. Names from the catalogue
      # are substituted into the query through `quote_table_name` — otherwise
      # this is a hole for an injection through somebody else's name.
      def drop_views!(c = conn)
        names = c.select_values(<<~SQL.squish)
          select table_name from information_schema.views
          where table_schema = current_schema() and table_name like 'v!_%' escape '!'
          order by table_name
        SQL
        return if names.empty?

        c.execute("drop view if exists #{names.map { |n| c.quote_table_name(n) }.join(', ')} cascade")
      end

      # Recreate the scratch database (for the structure from the repository).
      def recreate_database!(name)
        with_admin do |c|
          c.execute(%(drop database if exists "#{name}"))
          c.execute(%(create database "#{name}"))
        end
      end

      def write_snapshot(source_name, cfg, data, duration_ms:, warnings: [])
        c = conn
        source_id = upsert_source(source_name, cfg)
        snapshot_id = c.select_value(<<~SQL.squish)
          insert into snapshots (source_id, git_sha, server_version, database_name, ok, warnings, duration_ms)
          values (#{c.quote(source_id)}, #{c.quote(Xref.git_sha)},
                  #{c.quote(data['server_version'])}, #{c.quote(data['database'])},
                  true, #{quote_text_array(warnings)}, #{c.quote(duration_ms)})
          returning id
        SQL

        insert_rows('db_tables', %w[snapshot_id name kind est_rows],
                    Array(data['tables']).map { |t| [snapshot_id, t['name'], t['kind'], t['est_rows']] })

        insert_rows('db_columns', %w[snapshot_id table_name column_name ordinal data_type not_null default_expr],
                    Array(data['columns']).map do |x|
                      [snapshot_id, x['table_name'], x['column_name'], x['ordinal'],
                       x['data_type'], x['not_null'], x['default_expr']]
                    end)

        insert_rows('db_indexes', %w[snapshot_id table_name index_name is_unique is_primary definition],
                    Array(data['indexes']).map do |x|
                      [snapshot_id, x['table_name'], x['index_name'],
                       x['is_unique'], x['is_primary'], x['definition']]
                    end)

        insert_rows('db_rules', %w[snapshot_id table_name rule_name event is_instead definition],
                    Array(data['rules']).map do |x|
                      [snapshot_id, x['table_name'], x['rule_name'], x['event'],
                       x['is_instead'], x['definition']]
                    end)

        insert_rows('db_triggers', %w[snapshot_id table_name trigger_name function_name definition],
                    Array(data['triggers']).map do |x|
                      [snapshot_id, x['table_name'], x['trigger_name'],
                       x['function_name'], x['definition']]
                    end)

        insert_rows('db_routines', %w[snapshot_id identity name kind language returns body],
                    Array(data['routines']).map do |x|
                      [snapshot_id, x['identity'], x['name'], x['kind'],
                       x['language'], x['returns'], x['body']]
                    end)

        insert_rows('db_constraints', %w[snapshot_id table_name constraint_name kind ref_table columns definition],
                    Array(data['constraints']).map do |x|
                      [snapshot_id, x['table_name'], x['constraint_name'],
                       x['kind'], x['ref_table'], x['columns'], x['definition']]
                    end)

        insert_rows('db_sequences', %w[snapshot_id name owned_by],
                    Array(data['sequences']).map { |x| [snapshot_id, x['name'], x['owned_by']] })

        prune_snapshots(source_id)
        snapshot_id
      end

      def write_failure(source_name, cfg, error, duration_ms:)
        c = conn
        source_id = upsert_source(source_name, cfg)
        c.execute(<<~SQL.squish)
          insert into snapshots (source_id, git_sha, ok, error, duration_ms)
          values (#{c.quote(source_id)}, #{c.quote(Xref.git_sha)}, false,
                  #{c.quote(error.to_s[0, 2000])}, #{c.quote(duration_ms)})
        SQL
      end

      def upsert_source(name, cfg)
        c = conn
        detail = cfg.except(:kind, :transport).to_h.transform_keys(&:to_s)
        c.select_value(<<~SQL.squish)
          insert into sources (name, kind, transport, detail)
          values (#{c.quote(name.to_s)}, #{c.quote(cfg[:kind].to_s)},
                  #{c.quote(cfg[:transport].to_s)}, #{c.quote(detail.to_json)}::jsonb)
          on conflict (name) do update
            set kind = excluded.kind, transport = excluded.transport, detail = excluded.detail
          returning id
        SQL
      end

      def current_sources
        conn.select_all('select source, taken_at, server_version, database_name from v_current order by source').to_a
      end

      # Table and column names from every source — candidates in the text are
      # looked up by them.
      def known_names
        rows = conn.select_values(<<~SQL.squish)
          select name from v_tables
          union
          select column_name from v_columns
        SQL
        Set.new(rows)
      end

      # Runtime facts are replaced wholesale: this is a snapshot of the current
      # code, and asking it "what used to be" is meaningless.
      def write_rails_facts(models:, associations:, routes:, controllers:, jobs: [], constants: [])
        c = conn
        c.execute('truncate app_models, app_associations, app_routes, app_controllers, app_jobs, app_constants')

        insert_rows('app_jobs', %w[job_key class_name cron places path],
                    jobs.uniq { |j| j.values_at(:job_key, :class_name, :cron) }
                        .map { |j| [j[:job_key], j[:class_name], j[:cron], pg_text_array(j[:places]), j[:path]] })

        insert_rows('app_constants', %w[constant path],
                    constants.uniq { |x| x[:constant] }.map { |x| x.values_at(:constant, :path) })

        insert_rows('app_models', %w[class_name table_name path primary_key base database],
                    models.uniq { |m| m[:class_name] }
                          .map { |m| m.values_at(:class_name, :table_name, :path, :primary_key, :base, :database) })

        insert_rows('app_associations', %w[class_name name macro target foreign_key],
                    associations.uniq { |a| [a[:class_name], a[:name]] }
                                .map { |a| a.values_at(:class_name, :name, :macro, :target, :foreign_key) })

        insert_rows('app_routes', %w[verb path controller action controller_class route_name],
                    routes.uniq { |r| r.values_at(:verb, :path, :controller, :action) }
                          .map { |r| r.values_at(:verb, :path, :controller, :action, :controller_class, :route_name) })

        insert_rows('app_controllers', %w[class_name path actions],
                    controllers.uniq { |x| x[:class_name] }
                               .map { |x| [x[:class_name], x[:path], pg_text_array(x[:actions])] })
      end

      def write_run_place(place, cfg, units)
        c = conn
        c.execute(<<~SQL.squish)
          insert into run_places (place, env_id, ssh_host, container)
          values (#{c.quote(place.to_s)}, #{c.quote(cfg[:env_id].to_s)},
                  #{c.quote(cfg[:ssh_host].to_s)}, #{c.quote(cfg[:container_match].to_s)})
          on conflict (place) do update
            set env_id = excluded.env_id, ssh_host = excluded.ssh_host,
                container = excluded.container
        SQL
        c.execute("delete from run_units where place = #{c.quote(place.to_s)}")
        insert_rows('run_units', %w[place unit command rake_task],
                    units.map { |u| [place.to_s, u[:unit], u[:command], u[:rake_task]] })
      end

      # Which actions were requested at all. Kept apart from the renders: an
      # action answering with a redirect or with JSON renders no templates and
      # by view_runtime is indistinguishable from a dead one.
      def write_action_runtime(place, host, day, rows)
        c = conn
        c.execute(<<~SQL.squish)
          delete from action_runtime
          where place = #{c.quote(place.to_s)} and host = #{c.quote(host.to_s)} and day = #{c.quote(day.to_s)}
        SQL
        insert_rows('action_runtime', %w[place host day action hits],
                    rows.map { |r| [place.to_s, host.to_s, day.to_s, r[:action], r[:hits]] })
      end

      def write_view_runtime(place, host, day, rows)
        c = conn
        c.execute(<<~SQL.squish)
          delete from view_runtime
          where place = #{c.quote(place.to_s)} and host = #{c.quote(host.to_s)} and day = #{c.quote(day.to_s)}
        SQL
        insert_rows('view_runtime', %w[place host day action template path hits],
                    rows.map do |r|
                      [place.to_s, host.to_s, day.to_s, r[:action], r[:template],
                       ViewRuntime.template_path(r[:template]), r[:hits]]
                    end)
      end

      # Fill rates and index scans: facts from one pass over a source. An empty
      # result does NOT erase the previous one — exactly the mistake that once
      # lost a collected snapshot of the logs.
      # Translation keys: a full replacement, no history needed here — this is a
      # snapshot of the files of the tree rather than of an external source.
      def write_locale_keys(rows)
        return 0 if rows.blank?

        c = conn
        c.execute('delete from locale_keys')
        insert_rows('locale_keys', %w[lang key file],
                    rows.reject { |row| row[:key].to_s.empty? }
                        .uniq { |row| [row[:lang], row[:key], row[:file]] }
                        .map { |row| [row[:lang], row[:key], row[:file]] })
        rows.size
      end

      def write_env_keys(place, names)
        return 0 if names.blank?

        c = conn
        c.execute("delete from env_keys where place = #{c.quote(place.to_s)}")
        insert_rows('env_keys', %w[place name], names.map { |name| [place.to_s, name] })
        names.size
      end

      def write_migrations(source, versions)
        return 0 if versions.blank?

        c = conn
        c.execute("delete from db_migrations where source = #{c.quote(source.to_s)}")
        insert_rows('db_migrations', %w[source version],
                    versions.map { |version| [source.to_s, version] })
        versions.size
      end

      # Query skeletons from the logs. An empty answer does NOT erase what was
      # collected: a log for a day may sit on the node and contain not a single
      # SQL line, and `delete+insert` with an empty list would destroy the
      # previous snapshot — that is how a collection was lost once.
      # Days of production logs ACCUMULATE: only the same day of the same node
      # is deleted. That is the key property — the observation window grows by
      # itself with every collection, and "not touched in production" gets
      # stronger the wider the window is.
      #
      # But it must not grow forever: there are about five thousand skeletons a
      # day, and in a year that is a million and a half rows answering nobody's
      # question. The tail beyond KEEP_RUNTIME_DAYS is cut right here, in one
      # movement with the insert.
      KEEP_RUNTIME_DAYS = 120

      def write_sql_runtime(place, rows)
        return 0 if rows.blank?

        c = conn
        days = rows.map { |row| c.quote(row[:day].to_s) }.uniq.join(',')
        hosts = rows.map { |row| c.quote(row[:host]) }.uniq.join(',')
        c.execute("delete from sql_runtime where place = #{c.quote(place.to_s)} " \
                  "and day in (#{days}) and host in (#{hosts})")
        c.execute("delete from sql_runtime where day < current_date - #{KEEP_RUNTIME_DAYS}")
        insert_rows('sql_runtime',
                    %w[place host day digest skeleton hits tables columns filters writes parsed],
                    rows.map do |row|
                      [place.to_s, row[:host], row[:day].to_s,
                       Digest::SHA1.hexdigest(row[:skeleton])[0, 16], row[:skeleton], row[:hits],
                       pg_array(row[:tables]), pg_array(row[:columns]), pg_array(row[:filters]),
                       pg_array(row[:writes]), row[:parsed]]
                    end)
        rows.size
      end

      def pg_array(list)
        "{#{Array(list).map { |item| %("#{item.to_s.gsub('"', '\\"')}") }.join(',')}}"
      end

      def write_column_fill(source, rows)
        return 0 if rows.blank?

        c = conn
        tables = rows.map { |row| c.quote(row[:table_name]) }.uniq.join(',')
        c.execute("delete from column_fill where source = #{c.quote(source.to_s)} " \
                  "and table_name in (#{tables})")
        insert_rows('column_fill',
                    %w[source table_name column_name rows_total rows_recent filled off_default
                       filled_recent recent_by],
                    rows.map do |row|
                      [source.to_s, row[:table_name], row[:column_name], row[:rows_total],
                       row[:rows_recent], row[:filled], row[:off_default], row[:filled_recent],
                       row[:recent_by]]
                    end)
        rows.size
      end

      def write_index_usage(source, rows)
        return 0 if rows.blank?

        c = conn
        c.execute("delete from index_usage where source = #{c.quote(source.to_s)}")
        insert_rows('index_usage',
                    %w[source table_name index_name scans size_bytes is_unique is_primary since],
                    rows.map do |row|
                      [source.to_s, row[:table_name], row[:index_name], row[:scans],
                       row[:size_bytes], row[:is_unique], row[:is_primary], row[:since]]
                    end)
        rows.size
      end

      def write_json_keys(source, keys)
        c = conn
        c.execute("delete from json_keys where source = #{c.quote(source.to_s)}")
        insert_rows('json_keys', %w[source table_name column_name key hits],
                    keys.map { |k| [source.to_s, k[:table_name], k[:column_name], k[:key], k[:hits]] })
      end

      def app_constant_names
        Set.new(conn.select_values('select constant from app_constants'))
      end

      # Model -> table: needed by the scanner so that `BigUser.where(g1: 1)`
      # knows which table the column belongs to.
      def model_tables
        conn.select_rows('select class_name, table_name from app_models where table_name is not null').to_h
      end

      # The name of a field list -> its columns. Needed by the parser to link a
      # loop with the composition: `fields_for_legacy.each { |par|
      # member_info[par] }` reads exactly the columns in the list — and without
      # this link an access by variable is counted as a blind spot. The longest
      # composition per name is taken: the same list is sometimes declared both
      # in the code and in a configuration file.
      def column_lists
        rows = conn.select_rows(<<~SQL.squish)
          select distinct on (name) name, columns from v_column_lists
          order by name, cardinality(columns) desc
        SQL
        rows.to_h { |name, columns| [name, Array(columns)] }
      end

      # path => [file sha, digest of the parse inputs]
      # What is remembered about a file: the SHA, the digest of the inputs and
      # the modification time. The last one is for the gate in front of hashing
      # (see the DDL), so `nil` is legitimate here: rows written before the
      # column existed have no time, and they will simply be hashed once.
      def code_file_stamps
        conn.select_rows('select path, sha, coalesce(inputs_sha, \'\'), mtime from code_files')
            .to_h { |path, sha, inputs, mtime| [path, [sha, inputs, mtime&.to_f]] }
      end

      def code_file_shas
        conn.select_rows("select path, sha, coalesce(inputs_sha, '') from code_files")
            .to_h { |path, sha, inputs| [path, [sha, inputs]] }
      end

      # A digest of everything the parse depends on BESIDES the file itself.
      # It changes when the schema of any source changes and when the facts of
      # the application change.
      def input_digest(known:, model_tables:, app_constants:, column_lists: {}, scanner: nil,
                       idioms: nil)
        require 'digest'

        Digest::SHA1.hexdigest([known.to_a.sort.join(','),
                                model_tables.sort.to_a.join(','),
                                app_constants.to_a.sort.join(','),
                                # The composition of the field lists is an input
                                # of the parse too: which columns a loop over a
                                # list yields depends on it.
                                column_lists.sort.map { |name, cols| "#{name}:#{cols.size}" }.join(','),
                                # The habits of the tree from the configuration
                                # are just as much an input: add a name to
                                # `row_names` and there are more column reads
                                # with every file unchanged.
                                idioms.to_s,
                                scanner.to_s].join('|'))
      end

      # Which parts of the library PARTICIPATE in parsing a file. The rest (the
      # store, the reports, the text search, the verdict journal) do not affect
      # the parse result at all, while a digest over the whole directory forced
      # a re-parse of 21,494 files — 200 s — after an edit to any of them.
      #
      # The list is explicit, and the gate breaks in the safe direction: if any
      # named file is not in place (renamed, split up), the digest is computed
      # over THE WHOLE directory. It cannot narrow silently — and narrowing
      # silently is exactly what the trouble would look like: the parser was
      # edited and the tree was not re-parsed.
      #
      # But MAINTAINING the list by hand is a second hole of the same kind, and
      # it has already happened: `css.rb` appeared on 2026-10-10 and did not make
      # it into the list, which means an edit to the stylesheet parsing rules
      # caused no re-parse at all while the report looked fresh. So the
      # composition is checked by a spec against the parsers `code_scanner`
      # actually calls.
      SCANNER_FILES = %w[
        code_scanner.rb css.rb erb.rb js.rb markdown.rb nginx.rb shell.rb structured.rb
      ].freeze

      def scanner_files(paths)
        names = paths.to_h { |path| [File.basename(path), path] }
        return paths.sort unless SCANNER_FILES.all? { |name| names.key?(name) }

        SCANNER_FILES.map { |name| names[name] }.sort
      end

      # A digest of the parser itself. An edit to the parsing rules changes the
      # result with the files of the tree unchanged, exactly as a schema change
      # does — and without this only the files touched by hand get re-parsed
      # after such an edit.
      def scanner_digest
        require 'digest'

        files = scanner_files(Dir[Xref.root.join('lib/xref/*.rb').to_s])
        Digest::SHA1.hexdigest(files.map { |f| Digest::SHA1.file(f).hexdigest }.join)
      end

      # The age of the snapshots and the state of the parse — for the header of
      # any answer.
      def freshness
        conn.select_one(<<~SQL.squish)
          select (select max(taken_at) from snapshots where ok) as schema_at,
                 (select count(*) from snapshots s
                   join (select source_id, max(taken_at) as t from snapshots group by 1) m
                     on m.source_id = s.source_id and m.t = s.taken_at
                   where not s.ok) as failed_sources,
                 (select count(*) from code_files) as files,
                 (select count(distinct path) from code_refs where kind = 'scan_error') as scan_errors,
                 (select count(*) from code_refs where kind = 'sql_blind'
                   and detail->>'error' like '%парсер%') as parserless,
                 (select count(*) from code_refs where kind = 'sql_blind') as blind,
                 (select count(distinct inputs_sha) from code_files) as generations
        SQL
      end

      # Record a verdict about a finding. The file SHA is taken HERE, from the
      # index, rather than passed in from outside: a verdict must remember which
      # content of the file it was passed on, otherwise "false" hides the finding
      # forever.
      def record_verdict(kind:, subject:, verdict:, checked: 'глазами', reason: '', path: nil)
        c = conn
        sha = path.present? ? c.select_value("select sha from code_files where path = #{c.quote(path)}") : nil
        c.execute(<<~SQL.squish)
          insert into finding_verdicts (kind, subject, verdict, checked, reason, path, file_sha, git_sha)
          values (#{c.quote(kind)}, #{c.quote(subject)}, #{c.quote(verdict)},
                  #{c.quote(checked)}, #{c.quote(reason)}, #{c.quote(path.presence)},
                  #{c.quote(sha)}, #{c.quote(Xref.git_sha)})
          on conflict (kind, subject) do update
            set verdict = excluded.verdict, checked = excluded.checked, reason = excluded.reason,
                path = excluded.path, file_sha = excluded.file_sha, git_sha = excluded.git_sha,
                checked_at = now()
        SQL
      end

      def forget_verdict(kind:, subject:)
        c = conn
        c.delete(<<~SQL.squish)
          delete from finding_verdicts
          where kind = #{c.quote(kind)} and subject = #{c.quote(subject)}
        SQL
      end

      # The reliability of a class in one line: how many were verified and how
      # many of those turned out false. Printed next to the findings in every
      # report.
      def verdict_reliability(kind)
        conn.select_one("select * from v_finding_reliability where kind = #{conn.quote(kind)}")
      end

      def delete_code_files(paths)
        return if paths.empty?

        c = conn
        paths.each_slice(500) do |slice|
          c.execute("delete from code_files where path in (#{slice.map { |p| c.quote(p) }.join(',')})")
        end
      end

      # The index catch-up is started from ANY query (`bin/xref where`,
      # `callers`…), so two commands started at once parse the same files in a
      # race: on 2026-09-03 such a race brought `bin/xref callers` down with a
      # duplicate key on `code_files_pkey` — one process managed to insert a row
      # in the window between another's delete and insert. The write happens
      # under a per-path lock: the second waits and rewrites with the same
      # content instead of failing halfway. `code_refs` is protected
      # differently — there is `on conflict do nothing` in insert_rows. There is
      # no window at all: the file row is not deleted and re-inserted but
      # overwritten in a single statement. Both processes parse the same file and
      # write the same thing, so "who was last" changes nothing.
      def write_code_file(path, sha:, lang:, bytes:, refs:, inputs_sha: nil, mtime: nil)
        c = conn
        c.execute("delete from code_refs where path = #{c.quote(path)}")
        c.execute(<<~SQL.squish)
          insert into code_files (path, sha, lang, bytes, refs_count, git_sha, inputs_sha, mtime)
          values (#{c.quote(path)}, #{c.quote(sha)}, #{c.quote(lang)},
                  #{c.quote(bytes)}, #{c.quote(refs.size)}, #{c.quote(Xref.git_sha)},
                  #{c.quote(inputs_sha)}, #{mtime ? c.quote(mtime.to_f) : 'null'})
          on conflict (path) do update set sha = excluded.sha, lang = excluded.lang,
            bytes = excluded.bytes, refs_count = excluded.refs_count,
            git_sha = excluded.git_sha, inputs_sha = excluded.inputs_sha,
            mtime = excluded.mtime, indexed_at = now()
        SQL

        insert_rows('code_refs', %w[path kind token owner count lines detail],
                    refs.map do |r|
                      [path, r.kind, r.token[0, 500], r.owner, r.count,
                       pg_int_array(r.lines), r.detail&.to_json]
                    end)
      end

      private

      def pg_int_array(values)
        "{#{Array(values).map(&:to_i).join(',')}}"
      end

      def pg_text_array(values)
        "{#{Array(values).map { |v| %("#{v.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}") }.join(',')}}"
      end

      def with_admin
        Admin.establish_connection(admin_url)
        yield Admin.connection
      ensure
        Admin.remove_connection
      end

      def admin_url
        Xref.store_url.sub(%r{/[^/]+\z}, '/postgres')
      end

      def create_store_database!
        dbname = Xref.store_url[%r{/([^/]+)\z}, 1]
        with_admin { |c| c.execute(%(create database "#{dbname}")) }
      end

      # Public on purpose: `DbSql` writes its own rows with the same batch, and
      # there must not be a second batch inserter in the project.
      public def insert_rows(table, columns, rows)
        return if rows.empty?

        c = conn
        rows.each_slice(1000) do |slice|
          values = slice.map { |row| "(#{row.map { |v| c.quote(v) }.join(',')})" }.join(',')
          c.execute("insert into #{table} (#{columns.join(',')}) values #{values} on conflict do nothing")
        end
      end

      def quote_text_array(values)
        return "'{}'" if values.blank?

        c = conn
        "array[#{values.map { |v| c.quote(v.to_s) }.join(',')}]::text[]"
      end

      def prune_snapshots(source_id)
        c = conn
        c.execute(<<~SQL.squish)
          delete from snapshots where source_id = #{c.quote(source_id)} and id not in (
            select id from snapshots where source_id = #{c.quote(source_id)}
            order by taken_at desc, id desc limit #{KEEP_SNAPSHOTS}
          )
        SQL
      end
    end
  end
end
