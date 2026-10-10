# xref: a code index you can trust

**A specification, not an account of an idea.** Below is everything needed to
build the tool and get a working result without the "it does not work — let us
fix it" loop: the complete storage schema, the record contracts, working code for
the parses where a mistake is easiest to make, and the list of checks the result
is certified by.

What you get: a local database of facts about the code and about the environments,
plus a `bin/xref` wrapper over a set of tasks. No daemon, no service, no external
service. Nineteen thousand lines in one language — fifteen and a half of them the
tool itself and a little over three the specs — and the only dependency is your
database's SQL parser. A full parse of a tree of 21.5 thousand files takes three
minutes, the catch-up after an edit a fraction of a second.

The stack in the examples: Ruby/Rails + PostgreSQL. The techniques do not depend
on the platform; the places where it genuinely matters are marked. The code is
given as it works, not as an illustration: it is taken from a running tool and
anonymised.

**What exactly was verified, and how to run it — `verification.md`** next to this
file: the results of the control experiments point by point, and an honest list of
what was NOT checked.

**What is given here was verified by execution, not by proof-reading.** The whole
schema of part III and all the views of part V apply to a clean database without a
single error (31 tables, 65 views, every one of them answers a `select`); all
nineteen code fragments pass the syntax check; the log-parsing program was checked
on a sample and produces both counters. If something does not apply for you, it is
a matter of the database version, and that is worth saying rather than working
around.

**The numbers in the text are observations with a date, not properties of the
tool.** They age: the tree grows, layers are added, the false-finding rates fall as
checking goes on. Not one number from here is fit for somebody else's report
without a measurement of their own.

It was written out of the experience of an application of 600 thousand lines, 8
thousand files, twenty years of history, queries to the database written as
strings, and five live instances of the database with schemas that have drifted
apart. If your project is younger and entirely on an ORM — you need layers 1–3, the
rest as the need arises.

---

# Part I. Why

Text search and "find usages" answer the wrong question. Three reasons, each of
which cost an incident.

**A name is a poor key.** A short column name turns out to be, at the same time,
the name of a server in the infrastructure and the most popular name for a local
variable. The search gives three hundred matches, six of which have anything to do
with the database.

**A query lives in a string, not in code.** Where SQL is written as text, the
development environment does not know the string touches a table. To it, that is
just text. And then there is a substitution inside that string, and the table name
is assembled on the fly.

**The environments have drifted apart, and the code does not show it.** Once there
is more than one live database, sooner or later a table will exist in only some of
them. The code looks impeccable and fails only where the table is missing. This is
the worst class of error: it keeps quiet until production.

---

# Part II. What you get

```sh
bin/xref where users.email    # where a table or a column is touched: by a parsed
                              #   query, through the ORM, "looks like it by text" — apart
bin/xref column recover_      # which tables and which environments a column lives in
bin/xref blind                # the code reaches for a table absent in this environment
bin/xref drift                # how the environments' schemas differ from each other
bin/xref migrations           # which migrations are applied in each environment, what
                              #   is missing and where the environments diverged
bin/xref env                  # environment keys: the code reads it, the environment
                              #   has it not (NAMES only — values are never read)
bin/xref texts                # texts: a key is called and has no translation, and back
bin/xref holes [name]         # what is interpolated into a query, into which position
                              #   of the query, and where the text comes from
bin/xref calls [method]       # who calls it: from code, from a template, via send,
                              #   by symbol, by route
bin/xref callers <file>       # who refers to the file and who rendered it in production
bin/xref dead                 # unused: routes, actions, controllers, methods
                              #   (VIS=public — the public ones as well)
bin/xref changed [ref]        # what an edit touches: methods, their callers,
                              #   tables, and the environments missing those tables
bin/xref scope "<task>"       # from a task to files: entry points, a map, a reading
                              #   order, the tables at risk, the blind spots
bin/xref boundary <file>      # what to read before editing this file
bin/xref rules                # the architectural rules and their latches
bin/xref route /orders        # routes and controller files by a path pattern
bin/xref columns <table>      # by column: what is read, what is written, what is dead,
                              #   and what the live data says
bin/xref fill <table>         # a full scan of the data: fill rates, defaults,
                              #   a recent cohort, index scans
bin/xref lineage <tbl.col>    # where the value of a column comes from
bin/xref components           # the component model: roles, boundaries, cycles
bin/xref views                # which templates and actions worked in production
bin/xref sql [date]           # which queries RAN: patterns from the production logs,
                              #   resolved table names, columns in conditions
bin/xref sql profile [days]   # the same from the database's own statistics (pg_profile):
                              #   a window of weeks rather than days (IV.15)
bin/xref css                  # styles: what is declared, what keeps a file alive, which
                              #   classes nobody mentions, is there a rule IN THE CONTOUR
bin/xref js                   # javascript: the template→controller→method chain,
                              #   top-level functions, library calls
bin/xref docs                 # documents: broken links, stale paths, examples
bin/xref front                # the front-end configuration and dangerous places in scripts
bin/xref find "<pattern>"     # text search + what the index knows about the findings
bin/xref findings [class]     # findings by class: how many in the reports, how many
                              #   checked, the share of FALSE ones in the class (VI.3)
bin/xref verdict <class> <subject> false|real "why" [with what]
                              # checked against the first source — remember it
bin/xref locale               # the encoding self-check: what ruby sees with no locale
bin/xref audit                # an audit of the index itself: connectivity, noise, gaps
bin/xref refresh              # refresh the schemas, the application facts, the code
```

The collection commands (`schema`, `app`, `code`, `json`, `places`) are described
in part IV — they are rarely called from outside, as the queries catch the index up
on the changed files by themselves.

The wrapper is under a hundred lines of `sh` calling the collector's tasks
(`xref:schema`, `xref:code`, `xref:app`, …). Inside the tasks is ordinary SQL over
the index database.

---

# Part III. Contracts

Three things to fix BEFORE writing any code. If they are not fixed, everything will
have to be rewritten.

## III.1. The storage schema

In full. This is PostgreSQL; on another database only the array types and
`jsonb` change.

```sql
-- Schema sources: environments, a dump from the repository, a columnar store.
create table if not exists sources (
  id         serial primary key,
  name       text not null unique,
  kind       text not null,          -- 'pg' | 'hbase' | …: separates the namespaces
  transport  text not null,          -- how to fetch: activerecord | ssh_psql | structure_sql | thrift
  detail     jsonb not null default '{}'::jsonb
);

-- A snapshot of one source. The history is kept: it shows WHEN a column appeared.
create table if not exists snapshots (
  id             serial primary key,
  source_id      integer not null references sources(id) on delete cascade,
  taken_at       timestamptz not null default now(),
  git_sha        text,                -- which code it was taken on
  server_version text,
  database_name  text,
  ok             boolean not null default true,
  error          text,                -- a failed snapshot is a row too: it shows the source dropped out
  warnings       text[] not null default '{}',
  duration_ms    integer
);
create index if not exists idx_snapshots_source on snapshots (source_id, taken_at desc);

create table if not exists db_tables (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  name        text not null,
  kind        text not null,          -- r | p | v | m | f: table, partition, view, matview, foreign
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

-- The database holds not only structure but CODE: rewrite rules, triggers,
-- functions. Without them the answer "nobody reads this column" is sometimes a
-- lie: the rule `ON INSERT … DO INSTEAD UPDATE … SET x = x + new.x` reads the
-- column it increments. We turned out to have 165 such columns.
create table if not exists db_rules (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  table_name  text not null,
  rule_name   text not null,
  event       text not null,          -- insert | update | delete | select
  is_instead  boolean not null default false,
  definition  text not null,
  primary key (snapshot_id, table_name, rule_name)
);

create table if not exists db_triggers (
  snapshot_id   integer not null references snapshots(id) on delete cascade,
  table_name    text not null,
  trigger_name  text not null,
  function_name text,                 -- the body lives in a function, and that is what we parse
  definition    text not null,
  primary key (snapshot_id, table_name, trigger_name)
);

-- `identity` is the name with its argument types: functions can be overloaded.
create table if not exists db_routines (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  identity    text not null,
  name        text not null,
  kind        text not null,          -- function | procedure | aggregate | window
  language    text not null,
  returns     text,
  body        text,
  primary key (snapshot_id, identity)
);

-- A constraint is a consumer of a column too: the database will not let you touch
-- it silently.
create table if not exists db_constraints (
  snapshot_id     integer not null references snapshots(id) on delete cascade,
  table_name      text not null,
  constraint_name text not null,
  kind            text not null,      -- p | f | u | c | x | n
  ref_table       text,
  columns         text,               -- names from the catalogue, not by a regexp over text
  definition      text not null,
  primary key (snapshot_id, table_name, constraint_name)
);

create table if not exists db_sequences (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  name        text not null,
  owned_by    text,
  primary key (snapshot_id, name)
);

-- The parsed bodies of rules and functions. Separate from `code_refs`: these are
-- not files but database objects, and their life cycle is per-snapshot. They are
-- mixed into the same views, so "a rule reads this column" stands next to "the
-- code reads this column".
create table if not exists db_refs (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  object      text not null,
  object_kind text not null,          -- rule | trigger | routine
  kind        text not null,          -- pg_table | pg_column | pg_column_write | col_lineage
  token       text not null,
  owner       text not null default '',
  detail      jsonb,
  primary key (snapshot_id, object, kind, token, owner)
);

-- The code parse. `sha` is the key to incrementality.
create table if not exists code_files (
  path       text primary key,
  sha        text not null,
  lang       text not null,           -- ruby | view | js | sql | other
  bytes      integer,
  refs_count integer not null default 0,
  git_sha    text,
  -- A digest of the parse INPUTS: names from the schemas, the model map, the
  -- constant map. Without it a schema change invalidates nothing — the file's SHA
  -- is the same, while the candidate layer and the binding of columns to models
  -- are already different. That is exactly how an index can spend a month
  -- claiming a table is absent from two environments.
  inputs_sha text,
  indexed_at timestamptz not null default now()
);

-- The main table. One row per (file, record kind, name, owner) — NOT per
-- occurrence: otherwise a popular name yields hundreds of thousands of rows and
-- exactly as much use as one. The composition of `detail` is in III.2.
create table if not exists code_refs (
  path   text not null references code_files(path) on delete cascade,
  kind   text not null,
  token  text not null,
  owner  text not null default '',
  count  integer not null default 1,
  lines  integer[] not null default '{}',   -- the first 20 lines of the occurrence
  detail jsonb,
  primary key (path, kind, token, owner)
);
create index if not exists idx_code_refs_token on code_refs (token);
create index if not exists idx_code_refs_kind on code_refs (kind, token);
create index if not exists idx_code_refs_owner on code_refs (owner) where owner <> '';

-- Facts from the running application. They are refreshed wholesale and keep no
-- history: this is a snapshot of the current code, not of an external source.
create table if not exists app_models (
  class_name  text primary key,
  table_name  text,
  path        text,
  primary_key text,
  database    text,                   -- which connection the model is attributed to
  base        text                    -- the nearest abstract ancestor
);
create index if not exists idx_app_models_table on app_models (table_name);

create table if not exists app_associations (
  class_name  text not null,
  name        text not null,
  macro       text not null,          -- has_many | belongs_to | …
  target      text,                   -- the class at the other end
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
  actions    text[] not null default '{}'   -- public methods usable as an action
);

create table if not exists app_jobs (
  job_key    text not null,
  class_name text not null,
  cron       text,
  places     text[] not null default '{}',  -- in which environments the job is enabled ('*' — everywhere)
  path       text,
  primary key (job_key, class_name, cron)
);

-- The "constant -> file" map from the autoloader. Through it a reference to a
-- class becomes an edge of the "file -> file" graph — for free and exactly.
create table if not exists app_constants (
  constant text primary key,
  path     text not null
);
create index if not exists idx_app_constants_path on app_constants (path);

-- Where the code runs: the environments and the set of services, taken from the
-- live containers.
create table if not exists run_places (
  place     text primary key,
  env_id    text not null,            -- how the environment identifies itself inside the application
  ssh_host  text,
  container text
);

create table if not exists run_units (
  place     text not null,
  unit      text not null,
  command   text,
  task      text,                     -- if the service starts a collector task — its name
  taken_at  timestamptz not null default now(),
  primary key (place, unit)
);

-- Keys actually encountered inside schemaless fields. Not a schema, a sample.
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

-- What was rendered in production: the template and the action it was rendered from.
create table if not exists view_runtime (
  place    text not null,
  host     text not null,
  day      date not null,
  action   text not null default '',
  template text not null,
  path     text,                      -- the template reduced to a path in the repository
  hits     integer not null default 0,
  primary key (place, host, day, action, template)
);
create index if not exists idx_view_runtime_path on view_runtime (path);

-- Which actions were REQUESTED. Separate from the renders: an action that answers
-- with a redirect or with JSON renders no templates and is indistinguishable from
-- a dead one by view_runtime. Without this table the site root counts as dead.
create table if not exists action_runtime (
  place  text not null,
  host   text not null,
  day    date not null,
  action text not null,
  hits   integer not null default 0,
  primary key (place, host, day, action)
);
create index if not exists idx_action_runtime_action on action_runtime (action);

-- Which migrations are applied in each environment. This is DATA, not schema: the
-- set of what has been applied lives in a table and has to be asked for separately.
create table if not exists db_migrations (
  source     text not null,
  version    text not null,
  checked_at timestamptz not null default now(),
  primary key (source, version)
);

-- Which environment keys are SET in an environment. NAMES only: the values are cut
-- off on the node, before anything is sent, and the index does not have them.
create table if not exists env_keys (
  place      text not null,
  name       text not null,
  checked_at timestamptz not null default now(),
  primary key (place, name)
);

-- What lies in the translation store, by language. Read from the files, BYPASSING
-- the library: fallback languages hide a gap.
create table if not exists locale_keys (
  lang text not null,
  key  text not null,
  file text not null,
  primary key (lang, key, file)
);
create index if not exists idx_locale_keys_key on locale_keys (key);

-- Patterns of EXECUTED queries from the logs. There are no values here: the
-- literals are replaced on the node, before anything is sent. This is the only
-- source that knows the RESOLVED table name where the code assembles it by
-- interpolation.
create table if not exists sql_runtime (
  place    text not null,
  host     text not null,
  day      date not null,
  digest   text not null,              -- sha1 of the pattern: the row's key
  skeleton text not null,
  hits     bigint not null,
  tables   text[] not null default '{}',
  columns  text[] not null default '{}',   -- named in the output list: weak
  filters  text[] not null default '{}',   -- take part in a condition: strong
  writes   text[] not null default '{}',
  parsed   boolean not null default false, -- the pattern was trimmed and did not parse
  primary key (place, host, day, digest)
);

-- Column fill rates from LIVE data: a third level of proof next to the code and
-- the schema. `filled` — a value is present; `off_default` — differs from the
-- default (with `default 1` the first number is useless); `filled_recent` — for a
-- recent cohort, without which a mechanism that has died is indistinguishable
-- from a live one.
create table if not exists column_fill (
  source        text not null,
  table_name    text not null,
  column_name   text not null,
  rows_total    bigint not null,
  rows_recent   bigint,
  filled        bigint not null,
  off_default   bigint,
  filled_recent bigint,
  recent_by     text,                   -- which column the cohort was counted by
  measured_at   timestamptz not null default now(),
  primary key (source, table_name, column_name)
);

-- Index scans. `since` is mandatory: restarting the database resets the counters,
-- and without a date "zero scans" means nothing.
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

-- The journal of checked findings (VI.3). The class and the subject identify a
-- finding; `file_sha` is the content of the file at the moment of the check, and
-- without it a "false" verdict hides the finding for ever — including a real
-- problem that appears in the same place later. There is deliberately NO foreign
-- key to code_files here: a file may disappear, and a verdict about it has to
-- survive and say so out loud.
--
-- The words in `verdict` and `checked` are VALUES, not keywords — the running tool
-- stores them in its own language, and you can use yours.
create table if not exists finding_verdicts (
  kind       text not null,          -- the class of finding: see the class register
  subject    text not null,          -- how the finding is identified inside its class
  verdict    text not null,          -- 'настоящая' (real) | 'ложная' (false)
  checked    text not null default 'глазами',  -- by execution | by the schema | by data | by logs | by a spec | by eye
  reason     text not null default '',
  path       text,                   -- the file whose edit ages this verdict; null — never ages
  file_sha   text,
  git_sha    text,
  checked_at timestamptz not null default now(),
  primary key (kind, subject)
);
```

**The rules for handling this schema** — four of them, and all four were learned
the hard way:

1. **The DDL is applied on every run and is idempotent**: `create table if not
   exists`, `alter table … add column if not exists`. An analysis tool must have no
   migrations: it has to survive a branch switch in both directions.
2. **The views are all dropped and created anew**, in a single block before they
   are created. `create or replace view` cannot change the composition or the order
   of columns, and those will be changing constantly. The drop is `drop view if
   exists … cascade` in the reverse order of dependencies.
3. **A lock around the apply** (`pg_advisory_lock` with a fixed key): several
   processes work in one tree, and two simultaneous view drops produce a race.
4. **A separate connection** from the application's — so that nothing is mixed into
   its pool and its database. In Rails that is an abstract class with
   `establish_connection`.

## III.2. The record kinds of `code_refs`

The tool's main contract: it is where the parser and the reports meet. If it is not
fixed, the joins will not meet and the reports will start lying.

The rule the whole list obeys: **the reliability of a record is part of the
record.** A fact, a guess and a match by text are never mixed in any report.

| `kind` | `token` | `owner` | `detail` | Reliability |
| --- | --- | --- | --- | --- |
| `pg_table` | the table name | `''` | — | **fact**: the SQL was parsed by the database's parser |
| `pg_column` | the column name | the table, or `''` if undetermined | — | **fact** |
| `ar_column` | the column name | the model's table or `''` | — | a fact, if the root of the chain is a model class |
| `json_key` | the key | `table.column` (an unknown part is `?`) | — | **fact** |
| `def` | the method name | the owning class or `''` | `sql`, `returns`, `returns_part`, `singleton`, `visibility`, `params[]` | **fact** |
| `assign` | the variable name | the scope (`Class#method`) | `value`, `sql`, `part`, `op`, `literal`, `carrier`, `from`, `const`, `holes[]`, `more[]` | **fact** |
| `sql_hole` | the root of the expression | the position in the query (III.2.1) | `expr`, `scope`, `scopes[]`, `blind`, `fragment`, `carrier`, `call`, `const`, `sql` | **a fact about the substitution** |
| `const_ref` | the constant name | the scope (for collector tasks — the task name) | — | a fact of a reference, not of a call |
| `view_name` | the logical name of a template | `''` | — | fact |
| `render_ref` | the template name | `''` | — | **fact**: the name stands in the code in full |
| `render_dynamic` | the pattern or the expression | `skeleton` if there is a pattern; otherwise `''` | `glob`, `source`, `expr`, `root`, `scope` | **a candidate** or an honest "I do not know" |
| `task_entry` | the name of a collector task | `''` | — | fact |
| `hb_table` / `hb_column` | the table / `family:column` | `''` / the table | — | fact (literals in the calls) |
| `css_class` / `css_id` | the class / id name of a selector | `''` | — | **fact**: the rule is declared in this file |
| `css_import` | the path an `@import`/`@use` leads to | `''` | — | **fact**: the target was resolved in the tree |
| `css_package` | a reference to a PACKAGE (`tailwindcss`) | `''` | — | fact: the package's content is not read |
| `css_import_missing` | a target that does not exist in the tree | `''` | — | **a finding**, not an edge |
| `css_apply` | a class name inside `@apply` | `''` | — | **fact**: the stylesheet itself mentions the class |
| `html_class` | a class name from the markup or from code | `''` | — | **fact**: a literal in `class=`, `classList.add`, `data-…-class` |
| `html_class_pattern` | a name pattern (`btn-$1`) | `''` | `glob` | **a candidate** |
| `html_class_dynamic` | the whole expression | `''` | — | **a blind spot** |
| `pack_ref` / `pack_dynamic` | the name of a bundle named by a template | `''` | — | fact / a blind spot |
| `js_entry` | the path of a build root | `bundler` \| `package.json` | `pack`, `assembled` | a fact from the bundler's config |
| `js_import` / `js_package` / `js_import_missing` | a path in the tree / a package name / an unresolved target | `''` | — | an edge / an external dependency / **a finding** |
| `js_func` | the name of a top-level function | the scope (`Class`) | — | a fact of declaration |
| `js_call` | a name in a call position | `''` | — | **a lead**: a name is a poor key here too |
| `js_binding` | the name of an import binding | the package or the path | `mentions` | fact: it is what tells whether the library is called |
| `stimulus_register` / `stimulus_use` / `stimulus_target` / `stimulus_value` | the name of a controller, a target, a value | the way it is activated | — | fact: the registry and the markup |
| `pg_table_guess` | the name after `from`/`join` | `''` | — | **a guess**: the SQL did not parse |
| `token` | a name known to the database, met in text | `''` | — | **a candidate** |
| `sql_blind` | the beginning of an unparsed query | `''` | `error` | **a blind spot** |
| `hb_dynamic` | the name of the wrapper or `column X` | the table or `''` | `expr`, `skeleton`, `scope` | **a blind spot** |
| `scan_error` | the class of the error | `''` | `message` | **a blind spot** |

### III.2.1. Substitution positions

The `owner` of a `sql_hole` is the position in the query. The list is closed, and
the order of determination matters (IV.3).

| Value | What it means | How dangerous |
| --- | --- | --- |
| `table` | a table name is substituted | the index does not know which table the code touches |
| `glue` | the substitution is glued to a name | the same, plus shards |
| `in_list` | inside `in (…)` | a whole subquery may arrive |
| `condition` | a whole condition after `where`/`and`/`or`/`on`/`having` | the meaning of the query is not set by this string |
| `order_by`, `group_by` | the order or the grouping | a column name is substituted |
| `set` | an assignment in an `update` | the same |
| `select_list` | the list of selected fields | the same |
| `values` | inside `values (…)` | a value |
| `value` | to the right of a comparison | a value |
| `limit` | the selection limit | a value |
| `quoted` | inside quotes | a value |
| `other` | not recognised | look at it by eye |

### III.2.2. Deduplication and merging

The key is `(path, kind, token, owner)`. On a repeated occurrence: `count += 1`, the
line is added to `lines` (up to twenty). `detail` is taken from the first occurrence, but
two fields accumulate, otherwise the record lies:

- **`more`** — other expressions or values with the same key. `ids.join(',')` and
  `ids.map(&:to_i).join(',')` share a root and differ in meaning;
- **`scopes`** — the other scopes. The same substitution in three methods of a file
  yields one row, and the `scope` of the first of them lies about the rest.

```ruby
def add(kind, token, owner, line, detail: nil)
  token = token.to_s
  return if token.empty?

  ref = (@refs[[kind, token, owner.to_s]] ||= Ref.new(kind, token, owner.to_s, [], 0, detail))
  ref.count += 1
  ref.lines << line if ref.lines.size < MAX_LINES
  merge_detail(ref, detail) if detail && ref.detail && !ref.detail.equal?(detail)
end

def merge_detail(ref, detail)
  text = detail[:expr] || detail[:value]
  collect(ref.detail, :more, text) unless ref.detail[:expr] == text || ref.detail[:value] == text
  collect(ref.detail, :scopes, detail[:scope]) unless ref.detail[:scope] == detail[:scope]
end

def collect(store, key, text)
  return if text.blank?

  list = (store[key] ||= [])
  list << text if list.size < 4 && !list.include?(text)
end
```

## III.3. The configuration

One file — the single source of truth about addresses, sources and rules. The
example is complete; the environment names are made up.

```yaml
# Where to put the index. A separate database, with no relation to the application.
store_url: <%= ENV.fetch('XREF_DATABASE_URL', 'postgresql:///xref') %>

# The schema is fetched from every source SEPARATELY: there is no such thing as
# "the schema in general".
# transport:
#   activerecord  — through the application's connection (the local database)
#   ssh_psql      — ssh <ssh_host> docker exec -i <container> psql …
#   structure_sql — a schema dump loaded into a temporary database
#   thrift        — a columnar store
sources:
  repo:
    kind: pg
    transport: structure_sql
    path: db/structure.sql
    scratch_database: xref_repo
    comment: the schema from the repository is as much a source as the live ones

  local:
    kind: pg
    transport: activerecord
    comment: the development database

  prod_a:
    kind: pg
    transport: ssh_psql
    ssh_host: node-a1            # the node where the PRIMARY database lives, not a replica
    container: pg_primary        # a PATTERN for the name, not the exact name: see IV.1
    user: postgres
    database: app
    comment: >-
      fetch from the primary only: a replica lags, and after a migration you will
      get a false "there is no such column"

  prod_b:
    kind: pg
    transport: ssh_psql
    ssh_host: node-b1
    container: pg_primary
    user: postgres
    database: app

  stage:
    kind: pg
    transport: ssh_psql
    ssh_host: stage-1
    container: app_runtime       # psql inside the application's container
    user: app
    database: app

# Where to take the keys inside schemaless fields from. They have no schema: there
# is only what actually lies there. Poll SEVERAL environments and mark the source —
# if the data differs between environments, a key from staging is a trace of
# experiments, not a production fact.
json_sampling:
  sources: [prod_a, prod_b, stage]
  rows: 5000
  statement_timeout: 20s

# Production logs: where they lie and on which nodes. DATE is substituted with a date.
view_logs:
  places:
    prod_a:
      glob: '/var/log/app/DATE-web-*.log'
      hosts: [node-a1, node-a2, node-a3]
    prod_b:
      glob: '/var/log/app/DATE-web-*.log'
      hosts: [node-b1, node-b2]

# Where what runs. The set of services is taken from the live containers: an
# inventory maintained by hand always lags. The names of the places match the names
# of the schema sources — otherwise the reports cannot be joined.
run_places:
  prod_a:
    ssh_host: node-a1
    container_match: '^app_runtime'
    env_id: '2'
  prod_b:
    ssh_host: node-b1
    container_match: '^app_runtime'
    env_id: '3'

# Architectural rules: an edge of the graph from `from` to `to` is a violation.
# `limit` is a LATCH, not a norm: this much is tolerated today. The report keeps
# quiet until the number grows and shouts on the first new one. Without a latch a
# rule with three hundred old violations stops being read on the very first day.
rules:
  - name: a migration must not know about models
    from: 'db/migrate/%'
    to: 'app/models/%'
    why: the model gets renamed — replaying the migration dies mid-deploy
    limit: 7
  - name: a model must not pull in a controller
    from: 'app/models/%'
    to: 'app/controllers/%'
    why: a backwards dependency; in a background process there is no controller
    limit: 3
  - name: the old interface layer must not refer to the new one
    from: 'app/views/legacy/%'
    to: 'app/views/current/%'
    why: not a violation but a measure of an unfinished migration — the number must fall
    limit: 389
```

---

## III.4. The habits of a tree belong in the configuration, not in the parser

The least visible cause of unportability. Knowledge about ONE PARTICULAR tree
inevitably settles in the parser, and it looks like ordinary code:

- which methods are used here to take a result row out of the database
  (`select_all`, `find_by_sql`, and in our case also `MemberInfo.all`);
- what a variable holding a result row is customarily called (`row`, `info`,
  `anketa`);
- which wrappers of the columnar store take a TABLE as their first argument;
- which words after `from` are not tables (`lateral`, `unnest`, `cohort`);
- where the translations live (`config/locales`, and in our case also
  `config/site_locales`);
- whether non-ASCII inside a string that looks like a query counts as a sign of
  PROSE.

The last one is a good example of why this is not a matter of taste: in a
Russian-language tree "Select a valid review status" has to be told from SQL by the
presence of Cyrillic in the neighbouring lines, and in an English-only project that
rule will never fire and only misleads.

**The defaults belong in the code, the habits in the configuration.** The tool has
to work in a project with no configuration at all (otherwise nobody will try it),
so a generic set lives in the code and the configuration file replaces it. The
check: a spec substitutes the habits and makes sure the RESULT of the parse changes
— otherwise there is a "setting" with no effect (we have caught that already: the
list was moved out and the consumer of the list was forgotten, and it looked like a
working improvement).

**And the habits are an INPUT of the parse.** Add a name to the list of result-row
names — and there are more column reads with the files unchanged. So the digest of
the inputs must include the habits as well, otherwise editing the configuration
causes no re-parse while the report goes on counting by the old rules and looking
fresh.

**The numbers in the captions come from the data, not from memory.** The caption
"the shared legacy across 18 languages" asserted an untruth in somebody else's
project with two languages; now the number of languages is counted by a query. Any
number baked into a report's text is a statement about the tree, and it will go
stale.

---

# Part IV. Collection

## IV.1. The schemas of the environments

**One query to the system catalogue**, not to the portable views: the object's kind
is needed, and one and the same query has to work on every version you have alive.
It returns a single JSON document — easier to transfer and to store.

```sql
select json_build_object(
  'server_version', current_setting('server_version'),
  'database', current_database(),
  'tables', coalesce((select json_agg(t) from (
      select c.relname as name, c.relkind::text as kind, c.reltuples::bigint as est_rows
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r','p','v','m','f')
      order by c.relname) t), '[]'::json),
  'columns', coalesce((select json_agg(c) from (
      select cl.relname as table_name, a.attname as column_name, a.attnum as ordinal,
             format_type(a.atttypid, a.atttypmod) as data_type,
             a.attnotnull as not_null,
             pg_get_expr(d.adbin, d.adrelid) as default_expr
      from pg_attribute a
      join pg_class cl on cl.oid = a.attrelid
      join pg_namespace n on n.oid = cl.relnamespace
      left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
      where n.nspname = 'public' and a.attnum > 0 and not a.attisdropped
        and cl.relkind in ('r','p','v','m','f')
      order by cl.relname, a.attnum) c), '[]'::json),
  'indexes', coalesce((select json_agg(i) from (
      select t.relname as table_name, ir.relname as index_name,
             ix.indisunique as is_unique, ix.indisprimary as is_primary,
             pg_get_indexdef(ir.oid) as definition
      from pg_index ix
      join pg_class ir on ir.oid = ix.indexrelid
      join pg_class t on t.oid = ix.indrelid
      join pg_namespace n on n.oid = t.relnamespace
      where n.nspname = 'public'
      order by t.relname, ir.relname) i), '[]'::json)
)
```

**Transport to production.** There is usually no direct route to the database: the
container publishes a different port, and from a working machine there is no route
to the database's own port. Do not invent a tunnel — go in over ssh and run the
database client inside the container, passing the query on stdin:

```ruby
def ssh_psql(sql)
  out, err, status = Open3.capture3(
    'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
    cfg[:ssh_host].to_s, remote_psql_script,
    stdin_data: sql
  )
  raise Error, "#{name}: ssh returned #{status.exitstatus}: #{err.strip.lines.last(3).join(' ')}" unless status.success?

  out
end

# The container name in the configuration is a PATTERN, not the exact name. In an
# orchestrator the name carries the task's tail (`pg_primary.1.new3ic22ln…`) and
# changes on every restart of the service. We resolve it on the other side. Until
# this was in place the schema refresh silently fell off, and the index spent a
# week answering from an old snapshot.
def remote_psql_script
  match = Shellwords.escape("^#{Regexp.escape(cfg[:container].to_s)}(\\.|$)")
  psql = Shellwords.join(['psql', '-U', cfg[:user].to_s, '-d', cfg[:database].to_s,
                          '-At', '-q', '-f', '-'])
  <<~SH
    c=$(docker ps --format '{{.Names}}' | grep -E #{match} | head -1)
    if [ -z "$c" ]; then echo "no container matches the pattern" >&2; exit 1; fi
    exec docker exec -i "$c" #{psql}
  SH
end
```

**Do not parse the schema dump from the repository.** Load it into a temporary
database and fetch it with the same query as the live ones. Otherwise the project
acquires a second, home-made schema parser, and it will drift from the real one. A
side benefit: the dump and the local database start checking each other.

**A failed snapshot is a row too** in `snapshots` (`ok = false`, the error text).
Otherwise a source that has fallen off cannot be told from a source that does not
exist, and the reports start silently answering from the old snapshot. Show the age
of the snapshot in the reports about divergence.

**Fetch not only the structure but the CODE inside the database.** Rewrite rules,
triggers, functions, constraints, sequences. This is not completeness for its own
sake:

- **a rewrite rule changes the meaning of a query.** `ON INSERT … DO INSTEAD UPDATE`
  — an insert turns out to be an update. We have 59 such rules, and almost all of
  them are accumulators of the form `SET x = x + new.x`, that is, the column the
  rule increments is also the column it READS. Until the rule bodies were parsed,
  165 columns looked unread — an error in the dangerous direction: "can be
  deleted";
- **parse the bodies with the same parser** you parse the code with, and record them
  with the owner "rule X" instead of a file path. There must be no second parser of
  your own here. A subtlety: in `CREATE RULE` the actions sit in NESTED nodes, and
  those are what has to be walked, otherwise the write targets inside the rule are
  invisible;
- **a body in a procedural language will not be parsed by the database's parser** —
  it only knows the outer `CREATE FUNCTION`. Mark those with a separate, weaker
  class, "not parsed, language such-and-such", rather than with silence;
- **a constraint is a consumer of a column.** Take the column names from the
  catalogue rather than by a regexp over the definition text: `CHECK ((age > 0))`
  does not yield to a regexp. Exclude `NOT NULL` and the primary key from the
  consumers — that is a property, not a reference. And remember that recent versions
  of the database keep `NOT NULL` in the same constraint catalogue as everything
  else;
- **for a table with a rewrite rule, print the warning as the FIRST line** of the
  report, before anything else: otherwise the reader will have drawn a conclusion
  from the numbers the rule changes.

## IV.2. Parsing the code: the incremental cycle

A hundred lines that change everything: the index can be caught up **before every
query**, and the discipline of "do not forget to reindex" disappears.

```ruby
def scan_code(full: false)
  Store.migrate!
  known         = Store.known_names        # column and table names from the snapshots
  model_tables  = Store.model_tables       # Class -> table
  app_constants = Store.app_constant_names # constant names from the autoloader

  # THE EXTENSIONS ARE THE GATE OF KNOWLEDGE, and a mistake here is unlike the
  # others: a missing extension does not make the answer poorer, it makes it
  # FALSE. The parser sees half of a chain and confidently reports a defect. In a
  # TypeScript project (2026-10-09) `.ts/.tsx` were not on this list, and the
  # report produced six findings: three "the controller is not registered" with
  # the registration sitting in `application.ts`, and three "there is no such
  # method" with the methods existing.
  # The sign of such a breakage is a ZERO in a layer's counter (zero controllers,
  # zero keys from templates, zero classes). A zero in the self-diagnosis is the
  # first thing to check.
  extensions = %w[.rb .rake .ru .erb .haml .slim .builder .jbuilder
                  .js .jsx .mjs .ts .tsx .mts .sql
                  .css .scss .sass .less
                  .md .markdown .yml .yaml .json .sh .bash .conf]
  # Schema dumps are the schema, not code that touches it: a dump holds every
  # sharded table, and all of them would land in "the code accesses this table".
  # The index does not parse its own files either: its DDL is about another
  # database.
  skip = %r{\A(vendor/|node_modules/|public/|db/[^/]+\.sql\z|lib/xref/|lib/tasks/xref\.rake\z)}

  files = `git ls-files -z`.split("\0")
          .select { |f| extensions.include?(File.extname(f)) }
          .reject { |f| f.match?(skip) }

  current = files.each_with_object({}) do |f, acc|
    acc[f] = Digest::SHA1.file(f).hexdigest if File.file?(f)
  end

  # The digest of the inputs: if the schema or the application facts changed,
  # EVERYTHING has to be parsed, even though not one file has changed.
  inputs = Store.input_digest(known: known, model_tables: model_tables,
                              app_constants: app_constants)

  stored  = Store.code_file_shas          # path => [the file's sha, the inputs digest]
  # Vanished files are counted ALWAYS, including on a full rebuild: otherwise rows
  # are left from files that have dropped out of the sweep.
  removed = stored.keys - current.keys
  changed = full ? current : current.reject { |path, sha| stored[path] == [sha, inputs] }

  Store.delete_code_files(removed) if removed.any?
  changed.each do |path, sha|
    source = File.read(path, encoding: 'UTF-8').scrub('')
    refs = CodeScanner.new(path, source, known: known, model_tables: model_tables,
                                         app_constants: app_constants).scan
    Store.write_code_file(path, sha: sha, lang: CodeScanner.language(path),
                                bytes: File.size(path), refs: refs)
  end
end
```

Writing one file means deleting its records and inserting the new ones **in a
single transaction**: an interrupted parse must not leave a file with half its
records.

**The digest of the inputs must include the checksum of the PARSER ITSELF**:
editing the parse rules changes the result with the tree's files unchanged exactly
as a schema change does. Computing it over the whole tool directory is expensive
(for us, editing a report forced a re-parse of 21,494 files, 200 seconds), so only
the PARTICIPANTS of the parse are taken. And there are two holes here, both ours:

- **narrowing silently is not allowed.** If even one named participant is not in
  place (renamed, split up), the digest is computed over the whole directory: the
  gate breaks towards extra work rather than towards a missed edit;
- **maintaining the list by hand is the same hole from the other side.** We added
  the stylesheet layer and forgot to write its parser in: for a day, editing the
  stylesheet parse rules caused no re-parse at all, while the report looked fresh.
  The cure is not attentiveness but a check: the set of participants is compared
  with WHOM the parser actually calls (parsing its own source is cheap and exact),
  and that is a spec, proven by removal.

## IV.3. Parsing SQL: the substitution and its position in the query

The subtlest part. This is where it is easiest to end up with a tool that invents
table names — and not to notice.

**A hole is `$1`, not `1`.** With a one, the string `"… from shard_#{n}"` parses as
the table `shard_1`: the index silently invents names that do not exist. `$1` is
legal in a value position and breaks the parse in a name position — and the place
honestly goes into the blind spots. One `$1` is not enough: the `$` character is
allowed in PostgreSQL identifiers, so **a hole glued to a name** is caught
separately.

```ruby
SQL_HOLE = '$1'
QUESTION_PLACEHOLDER = /(?<=[\s,(=<>])\?(?=[\s,)]|\z)/   # `where id = ?` is a substitution too
SQL_START = /\A\s*(select\s|insert\s+into\s|update\s+[a-z_"]|delete\s+from\s|with\s+[a-z_"])/i
IDENT_HEAD = /\A[A-Za-z0-9_$]/
IDENT_TAIL = /[A-Za-z0-9_$]\z/

# A rough check for "we are inside a string literal": inside quotes the glue
# `'%$1%'` is harmless, while `tbl$1` outside them is already an invented name.
def inside_string_literal?(text)
  text.count("'").odd?
end
```

**Assembling an interpolated string.** It returns four values: the text, whether
there was interpolation, whether a hole got glued to a name, and the holes
themselves with their offsets.

```ruby
# => [text, was_interpolated, hole_glued_to_a_name, holes]
# a hole: { expr: 'ids.join(",")', offset: 42, line: 17 }
def literal(node)
  case node
  when StringNode, SymbolNode
    [node.unescaped.scrub(''), false]
  when InterpolatedStringNode
    interpolated = false
    merged = false
    holes = []
    text = +''
    node.parts.each do |part|
      case part
      when StringNode
        chunk = part.unescaped.scrub('')
        merged ||= text.end_with?(SQL_HOLE) && chunk.match?(IDENT_HEAD) && !inside_string_literal?(text)
        text << chunk
      when InterpolatedStringNode
        # Adjacent literals glued by a line continuation (`"a " \` / `"b#{x}"`)
        # arrive from the parser as NESTED nodes. Until this was unfolded, every
        # such part collapsed into one whole hole: out of
        # `"INSERT … VALUES " "(#{a}, #{b})"` came `INSERT … VALUES $1`, that is,
        # half the query vanished and the query went into the blind spots.
        inner, inner_interp, inner_merged, inner_holes = literal(part)
        interpolated ||= inner_interp
        merged ||= inner_merged
        merged ||= text.match?(IDENT_TAIL) && inner.start_with?(SQL_HOLE) && !inside_string_literal?(text)
        merged ||= text.end_with?(SQL_HOLE) && inner.match?(IDENT_HEAD) && !inside_string_literal?(text)
        Array(inner_holes).each { |hole| holes << hole.merge(offset: text.length + hole[:offset]) }
        text << inner
      else
        interpolated = true
        merged ||= text.match?(IDENT_TAIL) && !inside_string_literal?(text)
        # A hole carries ITS OWN line, not the start of the literal: otherwise all
        # the holes of a multi-line query are shown on the first line and cannot
        # be found.
        holes << { expr: hole_expression(part), offset: text.length,
                   line: part.location.start_line }
        text << SQL_HOLE
      end
    end
    [text, interpolated, merged, holes]
  end
end
```

The parts of a glued literal have to be marked as "not standalone strings" and not
parsed separately — otherwise a stump goes into the blind spots next to the whole
query. The marking is recursive: nesting goes deeper than one level.

**The position of a substitution** is determined by the text to its left. The order
of the checks matters: this is not style but correctness. `where id in (` is
`in_list`, not `condition`; `from ` is `table`, while `from users_` is `glue`.

```ruby
def hole_context(sql, offset)
  left = sql[0, offset].to_s
  return 'quoted' if inside_string_literal?(left)

  case left.gsub(/\s+/, ' ')
  # Any position inside an unclosed `in (…)`, not only immediately after the
  # bracket: in `in ($1, $1)` the second hole is just like the first. But if a
  # select has started inside the bracket, we are already in a subquery and the
  # position there is a different one.
  when /\bin\s*\((?![^)]*\bselect\b)[^)(]*\z/i                then 'in_list'
  when /\b(?:from|join|into|update|table)\s+(?:only\s+)?\z/i  then 'table'
  when /\border by [\w.,() ]*\z/i                             then 'order_by'
  when /\bgroup by [\w.,() ]*\z/i                             then 'group_by'
  when /\b(?:limit|offset)\s+\z/i                             then 'limit'
  when /\bvalues\s*(?:\([^)]*)?\z/i                           then 'values'
  when /(?:=|<|>|<=|>=|<>|!=|\blike|\bilike)\s*\z/i           then 'value'
  when /\bset\s+[\w.,'"= ]*\z/i                               then 'set'
  when /\b(?:where|and|or|on|having)\s+\z/i                   then 'condition'
  when /[A-Za-z0-9_$]\z/                                      then 'glue'
  when /\bselect\b/i                                          then 'select_list'
  else 'other'
  end
end
```

**Parsing the query.** The substitution is replaced first, and only then is the
text handed to the database's parser. The holes are recorded BEFORE the question
marks are replaced — otherwise the offsets shift.

```ruby
def analyze_sql(sql, line, blind: false, holes: nil)
  @sql_here = true                      # the mark will go into the `def` record
  record_holes(sql, holes, line, blind: blind) if holes.present?
  sql = sql.gsub(QUESTION_PLACEHOLDER, SQL_HOLE)
  # A hole glued to a name: parsing is not allowed. The database considers
  # `shard_$1` a legal identifier, and the index would fill up with tables that
  # do not exist.
  return unparsed(sql, line, 'the name is assembled by interpolation') if blind
  return unparsed(sql, line, 'the parser is unavailable') unless pg_query?

  parsed  = PgQuery.parse(sql)
  aliases = parsed.aliases
  tables  = parsed.tables.map { |t| unqualify(t) }
  tables.each { |t| add('pg_table', t, '', line) }

  column_refs(parsed).each do |qualifier, column|
    owner = if qualifier.nil?
              tables.size == 1 ? tables.first : ''   # one table — the binding is unambiguous
            else
              unqualify(aliases[qualifier] || qualifier)
            end
    add('pg_column', column, owner, line)
  end

  json_keys(parsed).each do |base, key|
    next if key.include?(SQL_HOLE)      # the key is assembled by interpolation — a pattern, not a name
    table = tables.size == 1 ? tables.first : '?'
    add('json_key', key, "#{table}.#{base.presence || '?'}", line)
  end
rescue StandardError => e
  unparsed(sql, line, e.message)
end

# The parse failed: we mark a blind spot and pull the table name out by an
# expression — but as a SEPARATE kind, because this is a guess.
TABLE_GUESS = /\b(?:from|into|update|join)\s+(?:only\s+)?([a-z_][a-z0-9_]*)/i
GUESS_STOPLIST = %w[set now the only lateral values select where group order limit offset
                    generate_series unnest jsonb_array_elements regexp_split_to_table dual].freeze

def unparsed(sql, line, reason)
  add('sql_blind', sql.gsub(/\s+/, ' ').strip[0, 120], '', line, detail: { error: reason[0, 200] })
  sql.scan(TABLE_GUESS).flatten.map(&:downcase).uniq.each do |guess|
    add('pg_table_guess', guess, '', line) unless GUESS_STOPLIST.include?(guess)
  end
  nil
end
```

## IV.4. Query fragments

The least visible kind of substitution: `param_ar << "user_id in (#{sub})"`,
`return ["user_id in (#{sql})"] if sql`. There is no whole query nearby — no
`select`, no `from` — there is nothing to parse with, and this is what the eye
skips over most easily.

A hole in a fragment is recorded like any other (`fragment: true`), but the filter
is strict, otherwise it is pure noise:

```ruby
# A fragment: not a statement but a piece that will be glued together later.
SQL_FRAGMENT = /
  \A[\s(]*(?:
      (?:and|or|not|where|having|order\s+by|group\s+by|limit|offset|set|values|
         union|from|join|inner\s+join|left\s+join|right\s+join|on)\b
    | [a-z_][a-z0-9_."]*\s+(?:not\s+)?(?:in\s*\(|like\b|ilike\b|is\b|between\b)
  )
/xi
# The branch `name = …` is deliberately NOT here. With it, log lines and URL
# parameters went into the index: `"trace=#{id} n=#{n}"`, `"flm=#{a}&intp=#{b}"`,
# the human `"From #{who} on balance"` — sixteen false findings out of a hundred
# and seven.

# A sign of real SQL, and a strong one: `from` is deliberately not in it — on
# `from` the human "From … on balance" went into the index.
SQL_PART_MARK = /\b(?:select|where|join)\b|\bin\s*\(/i

# The positions for which a fragment is parsed at all. `value`, `quoted`, `limit`
# and `select_list` are not among them: those substitute a value, and fragments
# with values number in the tens of thousands in the code.
FRAGMENT_CONTEXTS = %w[in_list condition table glue order_by group_by set values].freeze
# …and these two need no SQL sign: "order by" does not occur in the middle of
# ordinary text.
FRAGMENT_SELF_EVIDENT = %w[order_by group_by].freeze
```

Recording a hole, with the gate:

```ruby
def record_holes(sql, holes, line, blind:, carrier: nil, fragment: false)
  whole  = sql.gsub(/\s+/, ' ').strip[0, 200]
  marked = fragment && sql.match?(SQL_PART_MARK)
  holes.each do |hole|
    expr = hole[:expr].to_s
    next if expr.empty?

    context = hole_context(sql, hole[:offset])
    if fragment
      next unless FRAGMENT_CONTEXTS.include?(context)
      next if !marked && !FRAGMENT_SELF_EVIDENT.include?(context)
    end

    root = hole_root(expr)
    hole_line = hole[:line] || line
    # One and the same hole can arrive twice (a fragment is parsed both on its own
    # and as the value of an assignment) — one row, not two occurrences.
    next unless @recorded_holes.add?([hole_line, hole[:offset], root])

    @wanted_roots << root unless root.empty?
    add('sql_hole', root.presence || expr[0, 60], context, hole_line,
        detail: { expr: expr[0, 200], scope: scope_name, blind: blind, sql: whole,
                  carrier: carrier, fragment: fragment,
                  call: expr_call(expr), const: (root if root.match?(/\A[A-Z]/)) })
  end
end

# The root of an expression: the name by which it can be looked up at all.
# `ids.map(&:to_i).join(',')` -> `ids`, `params[:sort]` -> `params`.
HOLE_ROOT = /\A[@$]{0,2}[A-Za-z_][A-Za-z0-9_]*[!?]?/
def hole_root(expr) = HOLE_ROOT.match(expr.to_s)&.to_s.to_s

# `Repo.new.take_all` — the carrier is not the class but its method. The root here
# is a constant, and the method cannot be found by it: what has to be looked up is
# `take_all`. In `ids.map(&:to_i)` the root is lower-case — there the last call is
# `map`, and there is nothing to look up by it.
def expr_call(expr)
  head = expr.to_s[/\A[A-Za-z_][\w:]*(?:\s*\.\s*[a-z_]\w*[!?]?)+/]
  return nil if head.nil? || !head.match?(/\A[A-Z]/)

  parts = head.split('.').map(&:strip)
  parts.pop if parts.size > 2 && parts.last == 'new'
  parts.last == 'new' ? nil : parts.last
end
```

**A variable that accumulates a query.** `sql = 'select …'` and then `sql << "
where id in (#{ids})"` — the most common way to assemble a query out of pieces.
The fragment cannot be parsed whole, but the hole in it is the same:

```ruby
def note_assign(name, value, line, operator)
  return if value.nil?

  text, interpolated, merged, holes = literal(value)
  source     = value.slice.to_s[0, 400]
  whole_sql  = text.to_s.match?(SQL_START)
  part_sql   = !whole_sql && text.to_s.match?(SQL_FRAGMENT) && text.to_s.match?(SQL_PART_MARK)
  # The order matters: "carries a query" is about what was there BEFORE this line.
  carrier    = @sql_vars.include?(name)
  @sql_vars << name if whole_sql

  record_holes(text, holes, line, blind: merged, carrier: name) if carrier && !whole_sql && holes.present?

  @assigns << {
    name: name, line: line, scope: scope_name, operator: operator, carrier: carrier,
    value: (text || source).gsub(/\s+/, ' ').strip[0, 200],
    sql: whole_sql, part: part_sql, literal: !text.nil?, interpolated: interpolated,
    # The value is not a string (`cond = build_cond`) — we remember WHAT it is
    # taken from: by that name the hole reaches through to the method that fills
    # it.
    from: text.nil? ? (expr_call(source) || hole_root(source)) : nil,
    const: (text.nil? && hole_root(source).match?(/\A[A-Z]/) ? hole_root(source) : nil),
    holes: Array(holes).map { |h| h[:expr] }.first(4)
  }
end
```

**Selecting which assignments to record.** Recording them all means inflating the
index with exactly what inflates a text search. A record enters the index if at
least one condition holds: the value looks like a query; the name is substituted
into a hole or into a template in this same file; the name is visible beyond the
file (`@`, `@@`, `$`, a constant). The other local variables are noise: there are
hundreds of thousands of them, and there is nothing to answer with them.

## IV.5. Declarations: visibility and "returns a query"

**Visibility is the key to a report about unused things.** For a private method
"there are no calls by name" is almost a proof: it cannot be called from outside
the class at all. For a public one the same thing only means "it is not called in
this tree". All four ways of setting visibility have to be taken into account,
otherwise half the methods will be marked wrongly:

```ruby
VISIBILITY = %w[private protected public].freeze

# `private` changes the visibility of everything declared below it in THIS body;
# the other three forms name methods explicitly.
def handle_visibility(node)
  name = node.name.to_s
  return unless VISIBILITY.include?(name) || name == 'private_class_method'
  return unless node.receiver.nil?

  level     = name == 'private_class_method' ? 'private' : name
  arguments = node.arguments&.arguments || []
  if arguments.empty?
    @visibility[-1] = level if VISIBILITY.include?(name)   # the switch in a class body
    return
  end

  @pending_visibility = level if arguments.any? { |a| a.is_a?(DefNode) }   # `private def x`
  arguments.each do |argument|                                            # `private :x, :y`
    next unless argument.is_a?(SymbolNode) || argument.is_a?(StringNode)

    @visibility_named[[@scope_stack.join('::'), argument.unescaped.to_s]] = level
  end
end
```

A visibility frame is created for every class and module body, and a **separate**
one for a block of class methods (`class << self`): that has its own independent
switch. `private :old_method` stands BELOW the declaration, so the by-name marks
are applied after the file has been walked, not during.

**"Returns a query" and "there is a query in the body" are different signs.** The
first is true of a handful, the second of almost any model (for us 75 against
2,123). Mix them up and half the repository lands in the report, and people stop
reading it.

```ruby
# => 'whole' | 'part' | nil
def sql_return_kind(node)
  body = node.body
  last = body.is_a?(StatementsNode) ? body.body.last : nil
  # Unwind the tail of calls: the dominant form is `<<~SQL.squish`, and without
  # unwinding it reads as a call rather than as a string.
  last = last.receiver while last.is_a?(CallNode) && last.receiver
  case last
  when LocalVariableReadNode, InstanceVariableReadNode
    @sql_vars.include?(last.name.to_s) ? 'whole' : nil
  else
    text, = literal(last)
    return 'whole' if text.to_s.match?(SQL_START)
    # `(user_id in (select …))` is not a statement but a complete condition. For a
    # hole it makes no difference: a piece of a query will be substituted.
    return 'part' if text.to_s.match?(SQL_FRAGMENT) && text.to_s.match?(SQL_PART_MARK)

    nil
  end
end
```

A branch at the end (`if a then sql1 else sql2 end`) does not land here — a known
shortfall. Better to fall short than to call every model method into the report.

**Record the method's parameters.** If the root of a hole is a parameter, then the
text comes from the caller, and the report has to say so rather than keep quiet.

## IV.6. Templates and render calls

**Parse render calls line by line rather than as a tree**: in a template the code
is sliced up by tags, and there is no whole tree there. Three outcomes for one
call, and the difference between them is the difference between a fact and a guess:

- the name stands in the code in full → a **fact** (`render_ref`);
- the name is assembled by interpolation, but there are literal pieces
  (`"layouts/#{kind}"`) → out of them a pattern `layouts/*` is assembled, and the
  pattern yields **candidate** edges;
- the name is entirely in a variable → an honest **blind spot**: there is nothing
  to say except that it exists.

The third case is mandatory. While such calls did not enter the index at all, the
tool did not say "I do not know" — it kept quiet, and the silence read as "there
are no links": the production site menu, with half a million renders a day,
counted as unreachable.

The subtleties without which the parse loses two thirds of the calls:

- **the old form with a trailing arrow dominates** (`render :partial => 'x'`), and
  one call may carry several keys — take them all;
- **check that the word stands in a call position**, not in the page's text and not
  in a comment: otherwise comments and hint strings from the tests land in the
  blind spots. The signs are unbalanced quotes to the left and a list of allowed
  predecessors;
- **escape the pattern with a tilde** rather than with a backslash: template names
  are full of underscores, and for `LIKE` that is a wildcard. For the same reason
  compare a name's suffix with `right()` rather than with `LIKE`.

**The logical name of a template** is the path without the template root, the
leading underscore and the extensions. DO LEAVE the interface-variant prefix in it:
the variants are reduced not by the parser but by the comparison on a suffix inside
the edges view. Then one name in the code leads into all the variants at once, and
the file's name is not lost.

**Finding calls inside templates** (needed for the question "who calls this
helper"): the parser will not build a tree, but real code can be assembled out of
the tags — exactly the way the template engine itself does it.

```ruby
ERB_TAG = /<%(?<kind>[=\-#]?)(?<code>.*?)-?%>/m

# The text between the tags is thrown away, the newlines are PRESERVED (otherwise
# the line numbers drift away from the file), and `<% if %>` and `<% end %>` from
# different tags come together into one expression.
def erb_ruby(source)
  out = +''
  position = 0
  each_erb_tag(source) do |code, _line, match|
    out << ("\n" * source[position...match.begin(0)].to_s.count("\n"))
    out << code << ' ; '
    position = match.end(0)
  end
  out << ("\n" * source[position..].to_s.count("\n"))
  out
end

def each_erb_tag(source)
  source.to_enum(:scan, ERB_TAG).each do
    match = Regexp.last_match
    code  = match[:kind] == '#' ? match[:code].gsub(/[^\n]/, ' ') : match[:code]  # a comment becomes spaces
    yield code, source[0...match.begin(0)].count("\n") + 1, match
  end
end
```

If the whole thing does not parse (a tag inside an attribute, a fragment spanning
two templates) — parse each tag separately: some of the calls are visible anyway.
Without parsing templates the answer to "who calls this" lies in the most common
direction: for one helper it came out as 4 calls instead of 19, with three thousand
templates sitting right there.

## IV.7. Facts from the running application

The cheapest layer and the most underrated. Boot the application, let it finish
loading all the classes, and ask it: the models with their tables and file paths,
the associations, the routes, the controllers with their actions, the schedule of
background jobs, and the "constant → file" map from the autoloader.

What matters:

- **do not guess what can be asked.** An attempt to compute "the class
  `UserProfile` lives in `user_profile.rb`" creates a second source of truth that
  will drift from the real one at the first non-standard name;
- **the constant map from the autoloader** turns a reference to a class into an
  edge of the "file → file" graph. It is the main supplier of edges;
- **take a model's table from the model**, not from the class name. A composite
  primary key arrives as an array — reduce it to a string;
- **which database a model is attributed to** should be determined by the nearest
  abstract ancestor rather than by the current connection: otherwise every model
  ends up in the main database;
- **wrap every call in a guard**: one model that dies when its metadata is touched
  must not bring down the collection. Record the failure rather than swallowing it.

## IV.8. Where the code runs

Needed if there is more than one environment or the code is split by roles (web,
workers, background robots). Take the set of services **from the live containers**:
what is running and which task it performs. An inventory maintained by hand always
lags.

Joining this layer with the first one gives the most valuable report in the set:
**the table is absent in this environment, and the code that touches it runs
precisely here.**

## IV.9. The contents of schemaless fields

For every JSON field: a limited selection of rows, an enumeration of the top-level
keys, a count. One statement per column and a timeout per statement — otherwise one
heavy column kills the whole collection. Read-only.

Collect from several environments and **mark the source**: a key met only on staging
is a trace of experiments, not a production fact.

## IV.10. Production logs

**Two different counters in one pass**, and they must not be mixed up:

```awk
/ Processing by / { i = index($0, "Processing by "); rest = substr($0, i + 14);
                    j = index(rest, " as "); if (j > 0) rest = substr(rest, 1, j - 1);
                    act = rest; a[act]++; next }
/ Rendered /      { i = index($0, "Rendered "); rest = substr($0, i + 9);
                    if (substr(rest, 1, 7) == "layout ") rest = substr(rest, 8);
                    j = index(rest, " ("); if (j > 0) rest = substr(rest, 1, j - 1);
                    sub(/[ \t]+$/, "", rest); if (rest == "") next; c[act "|" rest]++ }
END { for (k in a) print "A|" k "|" a[k]; for (k in c) print "V|" k "|" c[k] }
```

- `Rendered` — which template was rendered;
- `Processing by` — which ACTION was requested.

The difference is decisive: an action that answers with a redirect, with JSON or
with an empty body **renders no templates** and looks dead by the first counter.
That is how the site root landed among the dead for us.

Four rules:

1. **Parse on the machine where the logs lie.** They run to gigabytes a day; what
   travels back is a summary, not the logs. Pass the script to `ssh host sh -s` on
   stdin.
2. **Check whether binding** a template to an action is legitimate. For us it is
   exact because the worker is single-threaded: the lines come strictly in
   sequence. If you have threads — binding by adjacency is wrong, and you need a
   request identifier in the log line.
3. **Accumulate by day** and store with a breakdown by environment, node and day.
   One day proves use and says nothing about death.
4. **An empty answer must not overwrite what was collected.** A day's log may lie
   on the node and contain not one line of interest; the "delete the old and insert
   the new" scheme will destroy, with an empty list, a snapshot collected when the
   log was full. That is how a previously collected day disappeared for us. The
   rule: nothing to insert means nothing to delete, and tell "there are no logs"
   from "nothing was found in the logs".

## IV.11. "Which fields are not used in the code": a name in a list is not a use

The most common question put to an index like this — and the most easily spoiled.
If a table is selected with a whole field list (`select #{FIELDS} from users`), then
"the column is named in the code" means nothing: the list is named once and at once
for all the columns. A report built on the mention of a name answers "the direction
was not traced" and hides the answer.

A use of a column that arrived by such a query is when **the value is taken**:
`row['nickname']`, `info.fetch(:sex)`, `row.dig('meta')`. That is a separate record
kind, and without it there is no answer. Five cases have to be told apart, and the
first three are uses:

| kind | example | a use? |
| --- | --- | --- |
| a literal key | `row['nickname']` | yes; the link is by NAME — it has no table, and the report must say so |
| a pattern of a key or a name | `info["language#{num}_2"]` → `language$1_2` | yes, if the pattern is SELECTIVE (see below) |
| a name inside a string expression | `'paid_until-paid_from<…interval'` | yes; the link is by NAME |
| a variable key | `row[field]` in a loop over a list | no — a blind spot; print it as a number |
| a substitution in place of a column name | `"#{make_goal(g)} in (1,2)"` | no — print it with the file and the line |

`[]=` is not part of this count: `result['nick'] = …` is a write into one's own hash,
not a read of a column.

**The selectivity of a pattern.** A pattern assembled out of an interpolation looks
like convenient proof — and errs in the worst direction. For us the pattern `user_$1`
(from three SPECS that build the login string `"user_#{user_id}"`) declared thirteen
columns of one family used — exactly the ones nobody reads. Three conditions, each
from a real false positive:

1. the literal part is not empty — otherwise `$1_$1` matches 73 columns out of 99;
2. the pattern catches **no more than three or four** columns of the table:
   `language$1_2` catches four and says something about them, `user_$1` catches twenty
   and says nothing about anything;
3. it occurs somewhere other than the tests — a test does not make a column necessary
   to the product.

Do not throw unselective patterns away: print them as a separate warning next to the
list — "the names of these columns may be assembled in the code, look at them by eye" —
with the file and the line.

**A substitution in place of a column name.** `"#{make_goal(g)} in (#{list})"` — a
place like that easily fails to enter the index at all: the "query fragment" sign
usually requires a NAME to the left of the operator, and here the substitution
itself stands in the name's place. Allow a hole in that position and give it a
position of its own — `column`. Otherwise the "not used" list passes sentence on
columns whose name is never written in the tree: for us the whole series of eleven
columns built by one method looked like that.

**Four places where such a report misses, and all four in the same direction —
"not used" where it is read.** Each of them cost us a false line in the answer:

1. **templates.** If taking a value by key is looked for by the tree sweep while
   templates are parsed line by line, there will be ZERO accesses from templates —
   and that is invisible, because a zero looks like "the value is not taken".
   Assemble Ruby out of the template's tags (preserving the line numbers) and run
   the same parse over it. For us 9,249 accesses came from `.rb` and not one from
   templates; after the fix, 7,180. The assembly must be implemented ONCE for the
   whole index: two copies of "Ruby out of a template" drift apart silently;
2. **the beginning of a query.** `create table … as select` and `drop table` are
   queries too, and the first reads real columns. For us a thirty-column query
   began with `drop table if exists` and was not parsed at all;
3. **a string expression with no interpolation**:
   `"paid_until-paid_from<'32 days'::interval"`. It counts neither as a
   whole query nor as a fragment with a hole. Let the parser decide: `select
   <piece>` either parses or it does not. The mandatory condition is that the
   expression contains an OPERATION, otherwise the field list itself (`'a,b,c'`)
   parses as `select a,b,c` and declares every column of the list used;
4. **a copy of the table.** If two copies of the same data live in the schema, the
   column is often read on the copy. Formally that is a different table; an honest
   report says "the same column is read on <the copy>", otherwise the list looks
   like a sentence.

**Bind the result row to its table — otherwise `select *` stays an assumption for
ever.** An access by key knows the NAME of the column and does not know whose table
it belongs to, while the question is always asked about a table. Because of that
`select *` hangs over the whole report: the row arrives whole, anything can be taken
out of it, and "this column is not read" becomes unknown for any table that is ever
selected with a star (we have 150 of those).

Hence a temptation that must not be yielded to: counting `select *` as a use of all
the columns. Then no column is ever unused, and the report is useless. The opposite
decision — that the star proves nothing — is the right one, but it is a CHOICE rather
than a measurement, and it silently carries the whole answer.

Here is how it gets measured. The query lies in the same file as the read, and most
often in the same method:

```ruby
res = connection.select_all("select * from member_contacts where user_id=#{id}").to_a
res.each do |line|
  email = line['contact']        # ← a read of the column member_contacts.contact
end
```

Three steps, all three cheap:

1. remember which tables are named in a query **by file line** — the parse has
   counted that anyway;
2. on an assignment "variable ← the result of a query" remember the lines where that
   query stands. And separately the lines of a variable that CARRIES the query: `sql
   = "select * from t"` on one line, `res = select_all(sql)` on another;
3. for a loop over such a variable, bind the block parameter to the same source — and
   restore the previous value on leaving the loop, otherwise a second loop attributes
   its reads to the first one's table.

Two rules are mandatory. **Record the reads AFTER the walk, not during it:** the
variable may have been filled below the place where it is read. And **do not invent an
owner when the query named two tables** — attributing the column to either of them
means inventing it, and that record is later used to answer "the field is not used":
the error will travel in the most dangerous direction.

What this gives: an access by a VARIABLE key — exactly what the star hides — now knows
its table too. Where there are no such accesses either with this table or with an
unknown one (in the same files), **the star hides nothing**, and "this column is not
read" is a fact. For us that is 92 tables out of 150. And the caveat in the report is
computed from the same number as the breakdown above it in the report: two sections of
one page computed differently contradict each other on the very first run — which is
what happened to us.

A side consequence of the second fix is worth knowing in advance: **there will be more
blind spots.** For us 633 → 731, and ninety-seven of the increase are `create table …
partition of <substitution>`: before the fix such queries were not parsed at all and
did not enter the count. This is a move from silence into incompleteness, that is,
exactly what one is after: the number grew because the tool stopped pretending those
queries do not exist.

### A blind spot is the whole query, not one substitution

And here it is worth stopping, because the blind-spot count is the main measure of
one's own ignorance, and it is easy to get used to. Ours reached 731, and the right
question was not "how do we explain this" but "could they be made visible?". Taking
the composition apart showed: they were blind not because the code is
incomprehensible but **because the parse gave up too early**. Six rules cut the count
from 731 to 317.

**Parse in several passes, not in one.** A substitution `#{…}` is replaced with `$1`,
that is, with a PARAMETER. In a value position that is right, while in a name position
a parameter is illegal — and the query does not parse as a whole, together with the
tables, the columns and the write targets that have nothing to do with that
substitution. The ladder of passes:

1. `$1` — a parameter. Fit for values;
2. `xrefhole` — a NAME. Fit for `from #{t}`, `#{col} = 1`. Everything containing the
   marker is filtered out of the facts: `auth_sid#{i}` gives `auth_sidxrefhole`, and
   no such table exists — its literal prefix is taken as a guess;
3. a replacement BY POSITION of the hole: in a condition `true`, in `limit` a number,
   in `set` — `name=1`, in the definition list of a `create table` — `name integer`.
   The tool computes the position of a hole for the substitution report anyway, so this
   is free.

Three small things of the same kind, each one a class of findings: a hole AFTER a
complete condition requires a joint (`where x in ($1) $1` → `and true`); a literal
`#{…}` in single quotes is a hole too, not rubbish (in single quotes Ruby does not
expand it, and it reaches the parse as it is); and a phrase that begins with a keyword
("Select a valid review status") is not a query — tell it apart by the presence of
structure (`from`, a bracket, a comma, a comparison) rather than by its first word.

**Look up a table name held in a variable by its assignment.** `from #{table}` is not
a blind spot if `table = 'queue_journal'` stands in the same file: out of 137 such
places 52 were resolved for us. A frequent pattern is a choice of two (`slow? ? 'a2' :
'a'`): name BOTH names rather than the whole expression. And filter by the schema
snapshot: in `(group=='GLOM') ? 'users' : 'users_live'` there are quotes around the
condition's value as well.

**Separate "a piece" and "text" from a blind spot.** A string breaking off mid-word
(`insert into queue1`) and a phrase in a human language are not "there is a query here
and we do not know which". Keeping them in the ignorance count is lying about
yourself: for us that was 140 records out of 731.

**And print the categories separately** in the self-diagnosis: blind, resolved by
assignment, pieces. One shared count hides the fact that half of it is cured by
parsing.

The first of the four deserves a guard in the self-diagnosis: print accesses by key
SEPARATELY — from code and from templates — and shout if zero came from templates. A
zero there looks like "the value is not taken", that is, like permission to delete the
column.

And a rule derived in the same place: **proof from the tests is not use in the
product.** Count the tests separately and say it in words ("named only in the tests"),
otherwise one test silently removes a line from the answer.

And the last and most important thing about wording: the tool answers **"it is not
used in the code"**, not "it can be deleted". Whether the data in a field is needed is
a question for the product's owner; a `not null` constraint or the presence of data has
nothing to do with the question of use. Mixing those answers means answering something
other than what was asked.

## IV.12. What is applied in each environment

The environments' schemas do not drift apart by themselves, and the drift almost
always has a cause in the journal of applied migrations. The check costs one query
(`select version from schema_migrations` in each environment) and answers a question
that is otherwise learned in the middle of a deploy.

This is DATA, not schema: a schema snapshot holds tables and columns, while the set
of what has been applied is the contents of a table and has to be asked for
separately.

Separate the three cases deliberately, otherwise nobody reads the report:

1. **present in the tree, not applied in the environment** — a deployment risk,
   this is the main finding;
2. **applied, with no file in the tree** — the file was deleted or the migration
   came from another branch;
3. **old short numbers** (`15`, `16` — an inheritance from earlier framework
   versions): there are no files for them and there cannot be. If they are not
   separated out, the report will always shout about sixteen "extra" migrations, and
   people will stop reading it on the first day.

And **a comparison of the environments with each other**: if the production
environments agree while their schemas differ — then tables were created bypassing
the migrations, and that is where to look. For us it came out exactly so.

## IV.13. Environment keys: read the names, never the values

`ENV['KEY']` with the key absent returns `nil` SILENTLY — no error, no line in the
log. Comparing the names the code reads with the names set in the environment is a
cheap check against that silence. For us it found that message intake in one
environment had never been enabled at all.

**Collect NAMES only.** The values are secrets; `sed 's/=.*//'` on the node cuts
them off before anything is sent. The index has no values not because they are not
printed but because they are not there. And a tool like this must not be able to
change the environment at all.

**A key's name is sometimes NOT A LITERAL.** `ENV[LEASE_SECONDS_KEY]` is as much a
read as `ENV['LEASE_SECONDS']`, but a parse that only knows literals does not see
it, and the report says "it is set and nobody in the code reads it" about a setting
that is read. In somebody else's project that produced 104 keys "with no reader",
30-odd of them from one family; after resolving the constants 75 and 19 were left.
The cure is a "constant → string" map per file, substituted into the read index.

One subtlety because of which the map is sometimes empty: in a tree with
`frozen_string_literal` a constant is declared not with a literal but with a
**call** — `KEY = 'LEASE_SECONDS'.freeze`. In the parse tree that is a call node, not
a string one, and a naive collection of "constant = string literal" finds none at
all. Strip `.freeze`, `.dup`, `.to_s` from the right-hand side; for us the map then
gave 12 constants (and not one of them, to be honest, is substituted into `ENV[…]` —
in our tree the keys are written as literals, and the check is needed anyway: silence
from that cause is indistinguishable from absence).

**Three classes, otherwise nobody reads the report.** For us "the key is not set in
any environment" is 276 names; in that form the list is useless. The classes:

1. **with no fallback value** — `nil` will arrive, and this is a real finding (125);
2. **with a fallback value** (`ENV.fetch('X', 'y')`, `ENV['X'] || 'y'`) — a normal
   setting, not a hole (138). The `||` form is visible only at the parent: the walk
   goes top-down, and it has to be caught at the "or" node rather than at the call;
3. **read as a FLAG** (`if ENV['X']`, `unless ENV['X'].to_i.zero?`) — an empty value
   there is legitimate and means "switched off" (13).

**And separate out the task arguments.** `rake x LIMIT=10` reads the same
`ENV['LIMIT']`, but such a key does not have to be set in the environment: we have
370 of those, and without filtering them out the report began with `APPLY`, `LIMIT`,
`DAYS`.

**Not set in all environments** is a section of its own: the behaviour of the
environments drifts apart, and the cause is then looked for for hours.

## IV.14. Texts: read the store rather than asking the library

If fallback languages are enabled (`fallbacks`), then the check "is a translation
returned" through the library is green ALWAYS: where there is no translation,
English silently arrives. That is how we once got "all 38 keys are returned in all
18 languages" with sixteen untranslated, one of them on the first step of a wizard.
So read the store's files yourself and count the keys by language.

What the comparison "keys in the code against keys in the store" catches:

- **a key is called and does not exist** — a person will see "translation missing".
  Everything we found turned out to be a miss of the NAMESPACE (`general.refresh`
  with `home.refresh` existing), so print "exists as": a search by the last segment
  of the key turns the finding into a ready fix;
- **a key is missing in one of the main languages** — those are the ones that cover
  the rest as fallbacks, and a gap there is visible only in the raw store;
- **a key exists and nobody calls it** — the text is translated into eighteen
  languages, and there is nothing to show it with.

Four subtleties without which the count is wrong:

1. **plural forms are ONE key.** If `one`/`other` are counted as separate keys, the
   code calls `mail.count`, the store holds `mail.count.one` and `mail.count.other`,
   and the key counts as missing. A leaf is a hash all of whose keys are forms (`zero
   one two few many other`);
2. **a relative key** (`t('.title')`) is resolved BY POSITION: in a template by its
   path, in a controller by the class and the action. Without that half the keys are
   never found in the store;
3. **a key is sometimes a namespace.** `t('about')` returns a hash, and the code walks
   it as a list: such a key exists in the store as a prefix rather than as a leaf;
4. **an assembled key covers a whole namespace.** `t("menu.#{name}")` calls everything
   under `menu.`, and declaring its contents orphaned is untrue. But the pattern has to
   be SELECTIVE: a pattern made of a single substitution matches any key and explains
   everything at once, that is, nothing. Our threshold is four characters of literal
   part, and it removed three thousand false "orphans", leaving three thousand real
   ones.

And print the "orphans" **by file** rather than by name: nobody will read three
thousand names, while "this file has 1,370 unnecessary keys" is already a decision.

## IV.15. Queries that ran: the fourth level of proof

The largest blind area of a static parse is a name assembled by interpolation
(`shard_table#{i}`). Statically all that is known is "what the name is assembled
from". The application log writes the name already RESOLVED, and it is the only
source that closes this area rather than describing it.

The mechanics are the same as for the render logs: the parse happens ON THE NODE, and
what travels back is a summary. But two rules here are stricter.

**Values never leave the node, and normalisation comes FIRST.** Production SQL is
addresses, keys, the text of letters. The script on the node replaces the literals
before anything else: strings with `'x'`, numbers with `1`. What goes out is a pattern
and a counter. There are no values in the index and there cannot be — not "we do not
print them", but they are not there.

**Do not touch digits inside NAMES.** `queue2`, `sessions3`, `shard_table4` are
exactly the names the whole thing is done for. Replacing "any number" destroys them:
substitute only where the character before the number is neither a letter nor an
underscore.

```sh
sed -e "s/E'[^']*'/'x'/g" -e "s/'[^']*'/'x'/g" \
    -e 's/\([^A-Za-z0-9_$]\)[0-9][0-9.]*/\1 1/g' \
    -e "s/'x'\( *, *'x'\)\+/'x'/g" -e 's/\( 1\)\( *, *1\)\+/ 1/g' \
| cut -c1-1500 | sort | uniq -c | sort -rn
```

The pattern is trimmed — otherwise kilometre-long queries travel — but **it must not
be trimmed short**: a field list in production is six dozen names and nine hundred
characters, and with a cut at 400 the columns from the tail looked "untouched in
production". Print how many patterns failed to parse because of the trimming next to
the output.

**And the most important thing, which shows up at once: a column in a CONDITION is not
the same as a column in the output list.** In production the query selects the whole
field list, so "named in the selection" means exactly what a name in a field list
means: nothing. Whereas a column in `where`/`order by`/`set` is working — rows are
filtered by it. The class is taken from the node's PATH in the parse tree (`[:stmts, 0,
:stmt, :select_stmt, :where_clause, …]`) rather than by walking the subtree by hand:
the nodes return their children as hashes, and the reference to the node is lost. Count
this class both statically and from the logs — and then the answer "the field is not
used" can be checked a second way that knows nothing about the code: of our twenty-six
such columns, five appeared in the production logs, and all five only in the output
list.

### A second source of the same knowledge: the database's own statistics

The logs have one shortcoming, and it is not cured by care: **the window**. A log lives
for a day and is rotated, so a weekly cron job, a monthly report and a rarely
visited screen do not fall into a one-day window at all. Accumulating the logs
yourself means accumulating what the database already accumulates for you: the
query statistics collector (ours is pg_profile) keeps the snapshots of
`pg_stat_statements` as a history. On one of our sources that is **336 snapshots
over eight days** where the logs covered two, and it gave **67 tables the index had
seen neither in the logs nor in the parse**.

This does not contradict the rule "do not enable heavy diagnostics in production
for the sake of an analysis tool" (part IX): nothing has to be enabled — what has
to be done is to **ask for what production already collects**. If it does not
collect anything, the logs remain.

The rules are exactly those of the logs, and the formulation of the normalisation
too — only it is expressed in SQL and runs ON THE NODE:

```sql
with win as (   -- the window: the snapshots of the required server over N days
  select s.sample_id, s.server_id, s.sample_time::date as day
  from profile.samples s
  join profile.servers v on v.server_id = s.server_id and v.server_name = 'local'
  where s.sample_time >= current_date - 30
),
app as (        -- the application's database only: the statistics hold every database of the server
  select distinct d.sample_id, d.datid
  from profile.sample_stat_database d where d.datname = 'database_name'
)
select w.day, sum(st.calls) as hits,
       left(regexp_replace(
              regexp_replace(
                regexp_replace(
                  regexp_replace(l.query, '''[^'']*''', '''x''', 'g'),
                '([^A-Za-z0-9_$])[0-9][0-9.]*', '\1 1', 'g'),
              '''x''( *, *''x'')+', '''x''', 'g'),
            '\s+', ' ', 'g'), 1500) as skeleton
from profile.sample_statements st
join win w on w.sample_id = st.sample_id and w.server_id = st.server_id
join app a on a.sample_id = st.sample_id and a.datid = st.datid
join profile.stmt_list l on l.server_id = st.server_id and l.queryid_md5 = st.queryid_md5
-- Data statements only: the statistics also hold `SAVEPOINT $1` and
-- `SET application_name = $1` — millions of calls from which nothing about the
-- tree can be learned.
where l.query ~* '^[[:space:]]*(select|insert|update|delete|with)[[:space:]]'
group by 1, 3 having sum(st.calls) > 0
```

Four subtleties, each of which has already cost us a wrong answer:

1. **Normalisation is needed anyway, even though the text already has no literals.**
   In `pg_stat_statements` the parameters have been replaced with `$1` by the
   database itself — but not for every statement: some PostgreSQL does not
   parameterise. Relying on "there are no values there anyway" is not allowed, and
   the rule "values never leave the node" stands.
2. **`ON_ERROR_STOP=1` is not pedantry.** Without it the database client exits with
   ZERO on an error in the query, the output is empty, and the report honestly prints
   "0 patterns". Caught on the first run: the grouping by position in the
   concatenated string was wrong, and it looked like "the statistics hold nothing
   about us".
3. **Trim the pattern at a space, not at a character.** A cut in the middle of a name
   invents a table: `… from big_users` trimmed at 1,500 gave `big_`, and that name
   travelled into "a table that exists in no schema". The rule is shared with the
   logs.
4. **The window has to be asked of the source and printed.** How many snapshots the
   database remembers and for which dates is a separate query (`min/max(sample_time)`),
   and it must stand next to the answer: "untouched in production" over two days and
   over eight are different statements, and they look the same.

And an honest boundary: so far we have this collection configured on ONE source out
of three. So the window of the answers differs by source, and the report prints it
per source — one shared number here would be a lie.

## IV.16. Column fill rates: the third level of proof

The code and the schema answer only half of the question "can this column be
deleted". **"The code does not read it" and "there is nothing in the column" are
different statements**, and the decision requires both. The third collection is a
full scan of live data: how many rows are filled, how many differ from the default,
how many are filled for a recent cohort.

Three traps. Each of them spoiled the measurement once, when it was done by hand:

**The default.** With `default 1`, a column nobody has ever touched is, by the "not
zero" count, filled for every single row. What is significant is something else — how
many rows **differ from the default**. For one of our columns that is 17 rows out of
3.38 million: by the first count it is "alive", by the second a dummy. For its
neighbour, conversely, 208,353 people set something other than the default (switched a
notification off), and the code does not read that column anywhere — that is, people's
choice is silently ignored. Neither of those two conclusions can be reached without a
comparison with the default.

Exclude NULL from the "not the default" count: the question is "how many people set
something other than what is set by itself", and an empty value does not answer it.
Without that, a column with a default and a million NULLs comes out with more "not the
default" than "filled", and the number reads as nonsense.

**The type.** The "has a value" condition depends on the type, and a mistake here is
not cosmetic: `boolean <> 0` is a database error that kills the WHOLE query, and the
table is left with no measurement at all (rather than "with zeroes"). Text is compared
with an empty string, a date only with NULL, a boolean with itself.

Two consequences visible only on a large run, and we got both:

- **the list of numeric types must be a WHITELIST, not a blacklist.** While the
  condition `<> 0` was applied to everything that is "not text and not a date",
  `interval` fell onto it — and one duration column (`duration`) brought down the
  query for its table;
- **the failure of one table must not bring down the run.** The same error on the
  first attempt aborted a batch of 24 tables entirely: not one of them got measured,
  and the cause was in one. Catch the error per table, remember its text next to the
  result and move on — otherwise the price of one unknown type equals the price of the
  whole run.

**Recency.** The total count does not tell a dead mechanism from a live one. For one
column there are 141,006 fills in total and **one** among those who registered in the
past year. The second measure is the share in a recent cohort; if it is ten times
lower than the total, the mechanism is fading. Take the cohort column by name from a
short list of candidates and compare correctly: an epoch as a number and a real date
require different conditions.

```ruby
# One table — ONE pass: three counters per column in a single select.
parts = ['count(*)', recent ? "count(*) filter (where #{recent_cond})" : 'null::bigint']
columns.each do |name, type, default|
  filled = filled_condition(name, type)          # by type, otherwise the query dies
  parts << "count(*) filter (where #{filled})"
  parts << (default.present? ? "count(*) filter (where #{off_default(name, default)})" : 'null::bigint')
  parts << (recent_cond ? "count(*) filter (where #{recent_cond} and #{filled})" : 'null::bigint')
end
```

Do not sample: shares computed from a sample once overstated a problem by a factor of
seven hundred for us. The scan is full — 3.4 million rows and 99 columns take 53
seconds — and that is exactly why it is NOT part of the ordinary index refresh: a full
read of a production table is started by a person, not by a catch-up.

And print the COVERAGE of this measurement next to the answers that rest on it: we have
measured 28 tables (820 columns) out of eight hundred and something, that is, three per
cent. It is the most honest measure of how much we still do not know — and it also
explains why "nobody reads this column and there is no data in it" remains a statement
about the measured tables rather than about the database.

Alongside it, take the **index scans** from the database's statistics. An index nobody
has looked into is not "a superfluous field", but its price is the same: space and work
on every write (one pair of our tables has 38 unused indexes taking 551 MB). Store it
together with the date the counters were reset: restarting the database resets them,
and without that date "zero scans" means nothing.

## IV.17. Two checks that catch a breakage rather than something unused

Both came out of an attempt to answer the question "which fields are superfluous" — and
found not something superfluous but something broken.

**The code accesses a column that the table does not have in any environment.** For
tables such a check usually exists; for columns it is forgotten. For us the very
first run found **five production queries that cannot execute**, and in three of
them the error is a miss by one word (`last_added` instead of `added_at_time`,
`creation_time` instead of `created_data`). So print a "looks like" hint: a near
name from the same table turns the report into a ready fix.

For such a check not to lie, the column parse has to tell three cases apart,
otherwise it invents columns that do not exist:

- **a qualified star.** `select u.*` is a star belonging to `u`, not a column named
  `u`: such a reference has one string field, and it travels into the columns;
- **a subquery in `from`.** In `select b from (select … as b from t) x` the column
  `b` belongs to the subquery. An unqualified column may be bound to the query's
  only table only when there are no derived tables;
- **the alias of a computation.** `select abs(a - b) as abs … order by abs` — here
  `abs` is the name of an output column. Do not throw the record away (an alias name
  may coincide with a real column, and the read must not be lost) — do not invent an
  OWNER. And limit the rule to the `select` output list: in `update t set c = c + 1`
  the target is also "a name with an expression", and without that limit the read of
  `c` on the right loses its owner. Our own spec caught us on this.

**Defects in field lists.** If a column list is assembled in one place and
substituted into a query whole, its composition is as much a subject for checking as
the code:

- **a repeated name** inside the list. Deduplicating while parsing the composition is
  right, but the fact of the repetition has to be remembered — otherwise there is
  nothing to check it mechanically with;
- **a gap in a numeric series.** If the list has `opt4_1…opt4_4` and `opt4_6`, and the table
  also has `opt4_5` which is not in the list — that is almost always a typo. For us the
  repetition and the gap turned out to be one and the same typo: one name took
  another's place, and a column filled for 19,452 people is read by nobody. A human
  found it by eye; the check finds it in a second.

Bind the list to a table by the composition of its names (the share that match) and
filter out noise derived from REAL noise rather than invented in advance: for us that
is purely numeric and single-character "names" (the tree has a table with columns
`1`…`33` and another with `a`…`t`) and lists that are confidently bound to no table at
all. Print the counters of both checks in the self-diagnosis: the filtering is fitted
to today's tree, and if the number jumps, the first thing to look at is the parser, not
the code.

## The layers beyond the code: documents, settings, scripts, front-end configuration

This chapter is worth reading before deciding where the index's boundary lies. Ours
ran along the file extension for a long time: `.rb`, `.erb`, `.js`, `.sql` were parsed
— **8,291 files out of 23,337**. About the other 15 thousand the index kept quiet, and
the silence read as "there is nothing there". And here is what was there.

**Documentation is as much a source of statements about the tree as the code, and it
goes stale silently.** We have 12,243 `.md` files. A link to a removed file looks like
a link; the name of a dropped table reads as a current one. The parse yields headings
(sections — so that the answer points at a place rather than only at a file), links,
mentions of paths, and **code blocks parsed by the same parsers as the files**: a query
in a document that does not parse is an example nobody has ever checked.

Two rules without which this layer does harm:

1. **A separate record kind.** A mention of a table in a document is NOT an access to
   the table. Mixing them means declaring used what has merely been written about, and
   poisoning the tool's main answer.
2. **Words of prose do not enter the index.** A name counts as named only inside
   backticks or in a code block. Otherwise 157 MB of documents will drown the answers in
   matches of the kind "in the table below".

**And the main danger of this layer is a FALSE ALARM.** The first run gave 137 "broken
code examples". Checked by eye: fourteen are real. The rest are classes that are not
defects and have to be called by their names:

| class | the sign | why it is not a defect |
| --- | --- | --- |
| a sketch | `…`, `<data centre number>`, `<email>` | a human omission, and it is not meant to be executed |
| an excerpt | a break in the middle of `if`/`when`/`end` | a quotation of code, not code |
| a patch | lines starting with `-`/`+` | this is a diff |
| a piece of a query | begins with `from`/`where` | it is completed with a prefix and parses |
| a template | `:name`, `?`, `@TOOL@` | a substitution, not an error |
| another dialect | backticks, `MergeTree`, `CODEC` | valid SQL of another engine |
| the label lies | SQL sits in a `ruby` block | trust the CONTENT, not the label |

The same with links: of 632 "broken" ones, 617 turned out to be absolute paths into a
working directory that does not exist at all in somebody else's copy of the tree. 15
are real. **If the classes are not separated, the tool produces six hundred findings
where there are fifteen — and stops being a tool.**

What is found to the point: **1,346 paths named in documents and absent from the tree**
(for us one views directory is mentioned by 18 documents and the directory does not
exist), tables from queries in documents that are in no schema snapshot, and examples
that do not parse by any means.

**Settings: the main thing in them is not the keys but the ERB.** In `.yml` the
environment is read through ERB (`database.yml`, `cable.yml`, `storage.yml`), and while
YAML was not parsed, those reads were invisible while the report asserted "it is not
read in the code". The parse has two layers: first the Ruby out of the ERB tags (driven
by THE SAME walk as the Ruby files — there must be no separate branch), then the key
tree over the text with the ERB cut out by a marker (not by emptiness: `host: <%= … %>`
without a value stops being a pair).

**The values of the settings are not in the index and cannot be** — those are a
password, an address or a key. Only the names are recorded. And limit the depth:
inventories of past tasks gave us 42,945 records from 593 files, twenty thousand names
of the form `rows.0.status_semantics` that nobody will ever ask about.

**Shell scripts: one distinction decides everything.** An environment key read by a
script is as much a read as one from Ruby, and a heredoc with a query is parsed by the
same SQL parser. But `$sha`, `$img`, `$path`, `$attempt` are the script's own
variables, and there are more of them than of real keys: without the distinction **111
names out of 442** landed in "environment keys". The sign is twofold:

* a name the script ASSIGNS is its own. An assignment happens without an equals sign
  too: in a loop (`for host in …`), when reading a line (`read -r line`), at a
  declaration (`local tmp=`). There is one exception, and it is idiomatic:
  `VAR=${VAR:-default}` both assigns and reads the environment;
* **the case**: an environment key is written in capitals. An assignment is not always
  caught — a name may receive its value inside a heredoc that travels to the node whole.

The return: **133 keys are read by scripts only** for us, and before `.sh` was parsed
those names were in no class of the report at all — while some of them were asserted to
be "not read in the code", which was a direct untruth.

**The front-end configuration is the most expensive parse of these four**, because a
mistake in it DOES NOT CRASH: the front end quietly starts serving the wrong thing. Four
rules, and each has already cost us an incident: an unanchored virtual-host regular
expression (it ate two production addresses), `rewrite … last` (the choice of location
starts over, and the guards of one's own location are not applied), `http_404` in the
list of reasons to move on to the next upstream (every honest 404 is multiplied by the
number of nodes), and one's own `add_header Cache-Control` without `proxy_hide_header`
(the other header is not replaced).

And here too is a second lesson about false alarms. The first version of the rule about
`rewrite … last` gave 25 findings. But `rewrite … last` is in itself NORMAL and the only
way to rewrite a path; the trouble begins only where `limit_conn` or `add_header` stands
in the SAME location. With that condition there are two findings — and the second is
exactly the case that has already happened in production.

**JavaScript: what is worth parsing is not the language but the LINK with the markup.**
We do not have a full JavaScript parser and do not need one. The value comes from
elsewhere: module edges (`require`/`import` — do not forget either, we have 102 files on
one and 12 on the other) and the "markup → controller → its method" link, because a
controller is invoked not by code but by an attribute in a template, and no import graph
will show that.

Four rules without which this layer produces false findings:

1. **The registry is the only authority.** A name in an attribute means something only
   if it is registered (`application.register('name', Class)`). Without that check other
   people's attributes of the kind `data-bs-target` (Bootstrap) go into the findings —
   for us that was 70 places.
2. **Build roots are entry points, not dead files.** Nobody imports them
   by construction: the bundler starts from them. Until they are named as entry
   points, the whole of the JavaScript lies outside the reachability graph, and the
   roots themselves count as unreachable. The same place holds standalone scripts
   and files named in build commands (`package.json`): for us, after separating the
   classes, ZERO dead files were left out of 248 "unreachable" ones.
3. **A declaration comes in three forms** (`static targets = […]`, the same across
   several lines, `static get targets() { return […] }`), and missing any of them
   produces a false "the target is not declared": in our tree seven controllers out
   of twenty-one declare them with a getter.

4. **There are THREE kinds of activation, not one.** A controller is activated by a
   template's markup, but also by a helper on the back end (`'data-controller' =>
   'name'`, `data: { controller: 'name' }`) and by code at runtime
   (`el.dataset.controller = 'name'`, `setAttribute('data-controller', …)`). While
   the parse looked only at HTML, "activated by nobody" was said about three
   controllers, of which one is. The short key `controller:` is valid ONLY inside a
   `data:` hash — outside it that is routing, and we have 265 such places.

What is checked on this link and cannot be learned without it: an action pointing at
a method that does not exist (it does not crash — simply nothing happens), a
template with an unregistered controller (Stimulus silently skips an unknown name),
a target the controller never declared, a value with no default that the markup does
not set, and a controller that no template activates.

**The boundary, in summary.** After seven parses the index sees 21,585 files out of
23,411 (92 %). Not parsed: images, fonts, `node_modules` and `vendor`. And that is
no longer silence but a named list. The last two layers — stylesheets and JavaScript
functions — are in IV.18 and IV.19: each has a trap of its own, and both produce
findings in the dangerous direction of "this can be thrown away".

## IV.18. Stylesheets: declared, included, applied in a contour

The layer built last and asked about first: "which styles are not needed". There is
nothing to answer it with without a parse — but answering it WRONGLY is easier than
in any other layer, because a class name is assembled on the fly more often than a
table name is. So the order is this: the measure of ignorance first, the findings
after.

**Parse PARTIALLY, and that is a decision, not an economy.** Exactly three things
are needed: which classes are declared, which files include one another, and which
classes the stylesheet itself mentions (`@apply`). Property values, variables,
mixins and media conditions are not needed: nobody asks questions about them, and
parsing the cascade and specificity means a browser of your own. Our whole
stylesheet parser is 134 lines.

**Two SCSS traps, and each lies in the direction of "the class is not declared".**

```ruby
# `&-big` inside `.btn` declares `.btn-big` — that name is NOT in the file in full.
# Without assembling it, the report calls `btn-big` undeclared where a rule exists.
def selector_names(selector, parent)
  names = []
  selector.to_s.split(',').each do |part|
    part = part.strip
    next if part.empty?

    if part.start_with?('&')
      suffix = part[/\A&([-_A-Za-z0-9]*)/, 1].to_s
      Array(parent).each { |base| names << (suffix.empty? ? base : "#{base}#{suffix}") }
      # `&.active` and `& .inner` declare their own classes as well.
      names.concat(part.sub(/&([-_A-Za-z0-9]*)/, ' ').scan(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/).flatten)
    else
      names.concat(part.scan(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/).flatten)
    end
  end
  names.uniq
end
```

The second is **a partial file**: `@import 'base/reset'` leads to
`_base/_reset.scss`, that is, to a name with an underscore that the reference does
not carry. Without that rule every such import "leads nowhere" and the target counts
as needed by nobody.

**And a third, not from SCSS: a reference to a PACKAGE is not a broken reference.**
`@import 'tailwindcss'`, `@import 'bootstrap/dist/css/bootstrap.css'` are
node_modules, not a path in the tree. While they went into "leads nowhere", the
report called eleven live build lines broken; the real count was zero. The signs: a
non-relative path plus an existing package directory.

**What keeps a stylesheet alive — FOUR roads, and missing any of them produces a
dead file that is alive.** For us the first run said "four stylesheets are included
by nobody"; one of them really is:

| road | what it looks like |
| --- | --- |
| an `@import` from another stylesheet | an ordinary edge between files |
| a build entry | named in the bundler's config (`entryPoints`) |
| **an import from JavaScript** | `import '../css/uppy_upload.css'` in a bundle root — the bundler emits the CSS as a side output |
| **a path assembled in the config** | `path.join(root, 'app', 'javascript', 'x', 'x.css')` — the entry has no key carrying the name at all |

**A consumer of a class is four roads too**: a literal in the markup
(`class=`/`className=`), a helper on the back end (`class: 'btn'`), code at runtime
(`classList.add`, `addClass`, `toggleClass`) and Stimulus attributes
(`data-…-class`). And one rule about order, which I have already got wrong:

```ruby
def note_class_list(text, line)
  # THE ORDER DECIDES: mask the substitutions first, split on whitespace after.
  # The other way round, `class="btn btn-<%= kind %>"` falls apart into `<%=`,
  # `kind`, `%>`, and `kind` enters the index as a CLASS that does not exist in the
  # stylesheets at all.
  masked = text.to_s.gsub(/<%.*?%>/m, '$1').gsub(/\#\{[^}]*\}/, '$1')
  masked.split(/\s+/).reject(&:empty?).each do |word|
    if !word.include?('$1')
      add('html_class', word, '', line) if word.match?(/\A-?[A-Za-z_][A-Za-z0-9_-]*\z/)
    elsif word.delete('$1').match?(/[A-Za-z0-9]{2}/)
      add('html_class_pattern', word, '', line, detail: { glob: like_pattern(word) })
    else
      add('html_class_dynamic', text.to_s.strip, '', line)   # the layer's honest blindness
    end
  end
end
```

**The measure of ignorance is printed as the section's first line.** For us that is
**2,421 places where a class name is assembled IN FULL**, and 287 patterns. Two
thousand such places mean the list "nobody mentions this class" is a lower bound
rather than a sentence. On top of that the stylesheets from `node_modules` are not
read at all, so a library's class will always land in the class "there is no rule in
any of OUR stylesheets".

**The layer's main question is not "is this class dead" but "is there a rule IN THIS
CONTOUR".** A class may be alive in one template tree and do nothing in another, and
that is not death but a style that did not arrive. The chain: **the contour → the
bundle name from the layout → the build entry → `@import` → the file**. Three
subtleties:

- **take only a PROVABLE contour** — the one whose layout of the same name names a
  bundle. A directory of templates is not a contour: it is rendered under a layout
  chosen at runtime. My first version invented five such "contours" and confidently
  laid the styles out across them;
- **the bundle name of an assembled entry is taken BY A NAMING CONVENTION** (the file
  name without its extension), and that has to be said out loud. While the link was
  missing, a contour turned out to have not one style of its own, and the view answered
  "there is no rule in the contour" for all 632 classes — honestly and uselessly;
- **print the rule's file next to the name.** `gap-2` → "the rule is in
  `css/utils.css`" means "our utilities shim is not included in this contour", and
  that is a different decision from "the class is dead".

What this layer found for us: one stylesheet included by nobody (44 bytes), 569
declared classes with not a single mention — and they are visible **by file**, because
the decision is made per file: a compatibility shim that has outlived its need gives
itself away by its share (`theme_compat.css` — 34 names out of 95, `css3-icon.css` — 87
out of 151). And 207 classes of one contour whose rule lies in another: each is either
a style that did not arrive or a superfluous class in the markup.

## IV.19. JavaScript functions and libraries: count the calls, do not go inside

A continuation of the link from the previous chapter, but the question is a different
one: not "does the controller work" but "what can be thrown away here". The answer is
expensive: the first run gave **357 dead functions**, and the real count in the
application is **zero**.

**A declaration in three forms** (`function name`, `const name = (…) =>`,
`window.name = function`), and each has a trap: the head of a declaration itself
matches the call pattern. Without cutting it off, every declared function has a
"call" from its own line — and there are NEVER any dead ones.

**Mask non-code before looking for calls.** Strings, regular expressions and
template strings produce false calls, and everything after that reads as a finding
about the tree:

```ruby
masked = row.gsub(/'(?:\\.|[^'\\])*'/, "''").gsub(/"(?:\\.|[^"\\])*"/, '""')
            .gsub(%r{(?<=[=(,:\[!&|?+\s])/(?:\\.|[^/\\\n])+/[gimsuy]*}, '//')
# A template string is masked, while the substitutions from it are PRESERVED: in
# `${build(x)}` the call is real and the text around it is not.
masked = masked.gsub(/`(?:\\.|[^`\\])*`/) { |span| span.scan(/\$\{[^}]*\}/).join(' ') }
```

For us this is exactly where the finding "the tree calls lodash as a global" lived:
`_(` stood inside the regular expression `/^(?:letdiv)_\d+_(\d+)$/` and inside a
template string. Checked against the first source: it does not.

**`...fn()` is a spread, not a method access.** A call pattern usually cuts off
everything preceded by a dot — and then the call after a spread is lost and the
function counts as dead:

```ruby
CALL = /(?:(?<![.\w$])|(?<=\.\.\.))(?<name>[A-Za-z_$][\w$]*)\s*\(/
```

**And the main thing: "nobody calls it by name" is NOT the death of a function.**
The path from 357 to zero is instructive, because every step removed one way of
being alive:

| step | left |
| --- | ---: |
| there is no `name(` call | 357 |
| the name is mentioned nowhere (filtered by a text search) | 13 |
| search the WHOLE tree, not only the application directory | 6 |
| a class by place: a one-off script against the application | **0 in the application** |

A function is passed by value (`setTimeout(tick)`, `{ install: fn }`), exported (it
may be called by another file), called from a script outside the application. So
record a call by name as **a lead, not a fact**, and print that in words — exactly as
with names in Ruby.

**Libraries: do not go inside.** Inside a library "unused" is the majority by
construction, and one gets rid of it by a version bump rather than by rules. What
has to be counted is something else — **the import bindings** and the mentions of a
binding in the file's body: a package whose binding is mentioned nowhere is a dead
dependency, and that answer is useful. For us there are zero of those out of twelve.

As a separate line — **access as a GLOBAL, with no import**: that is the question
"can jQuery be thrown away". It is decided not by the import graph but by searching
for `$(` across the application's JavaScript — and in our tree it is not there even
once (the four matches are a comment and three lines of Ruby).

**A file nobody imports can be alive for five reasons**, and without classes they
all read as candidates for removal: a build root, a standalone script, a type
declaration (`.d.ts` — only the compiler reads it), a test run (`*.test.ts`), a build
setting (`*.config.js`). In somebody else's project the last three gave eight false
candidates, among which a real one would have been lost.

---

# Part V. The views

The reports are written against these views rather than against the tables directly.
The ones given here are those whose logic is not obvious.

**The last successful snapshot of every source** is the foundation of everything
else:

```sql
create view v_current as
select distinct on (s.source_id)
       s.id as snapshot_id, s.source_id, src.name as source, src.kind as source_kind,
       s.taken_at, s.git_sha, s.server_version, s.database_name
from snapshots s
join sources src on src.id = s.source_id
where s.ok
order by s.source_id, s.taken_at desc, s.id desc;

-- A relational database and a columnar one live in the same snapshot tables but in
-- DIFFERENT namespaces: one and the same name in the two of them is a different
-- thing.
create view v_tables as
select c.source, t.name, t.kind, t.est_rows
from db_tables t join v_current c on c.snapshot_id = t.snapshot_id
where c.source_kind = 'pg';

create view v_columns as
select c.source, col.table_name, col.column_name, col.ordinal,
       col.data_type, col.not_null, col.default_expr
from db_columns col join v_current c on c.snapshot_id = col.snapshot_id
where c.source_kind = 'pg';
```

**Where a table exists and where it does not.** `missing_in` is computed only over
sources of the same kind:

```sql
create view v_table_presence as
select g.name, g.present_in,
       array(select s.source from v_current s
             where s.source_kind = 'pg' and not (s.source = any(g.present_in))
             order by 1) as missing_in
from (select name, array_agg(source order by source) as present_in
      from v_tables group by name) g;

create view v_column_presence as
select g.table_name, g.column_name, g.present_in, g.types, g.types_by_source,
       array(select s.source from v_current s
             where s.source_kind = 'pg' and not (s.source = any(g.present_in))
             order by 1) as missing_in
from (select table_name, column_name,
             array_agg(source order by source) as present_in,
             array_agg(distinct data_type) as types,
             array_agg(source || ':' || data_type order by source) as types_by_source
      from v_columns group by table_name, column_name) g;

-- A column is not everywhere — but only for tables that are EVERYWHERE. Otherwise
-- the report drowns in the columns of one environment's backup tables.
create view v_column_drift as
select cp.* from v_column_presence cp
join v_table_presence tp on tp.name = cp.table_name
where cardinality(cp.missing_in) > 0 and cardinality(tp.missing_in) = 0;
```

**The edges of the graph.** A reference to a constant is only one sort of them; on
its own it leaves every template and every model association outside the graph.

```sql
create view v_const_edges as
select r.path as from_path, r.owner as scope, c.path as to_path, 'const' as kind
from code_refs r
join app_constants c on c.constant = r.token
where r.kind = 'const_ref' and c.path <> r.path;

-- A template name in the code leads into ALL the interface variants at once: their
-- logical name is shared, their files differ. The suffix is compared with right()
-- rather than LIKE: template names are full of underscores, and for LIKE that is a
-- wildcard.
create view v_render_edges as
select r.path as from_path, '' as scope, v.path as to_path, 'render' as kind
from code_refs r
join code_refs v
  on v.kind = 'view_name'
 and (v.token = r.token or right(v.token, length(r.token) + 1) = '/' || r.token)
where r.kind = 'render_ref' and v.path <> r.path;

-- A CANDIDATE edge: the name is finished off at runtime, but there is a pattern
-- made of the literal pieces. The tilde escaping is for the same reason.
create view v_render_candidate_edges as
select r.path as from_path, '' as scope, v.path as to_path, 'render?' as kind
from code_refs r
join code_refs v
  on v.kind = 'view_name'
 and (v.token like (r.detail->>'glob') escape '~'
      or v.token like ('%/' || (r.detail->>'glob')) escape '~')
where r.kind = 'render_dynamic' and r.owner = 'skeleton'
  and r.detail->>'glob' is not null and v.path <> r.path;

-- A controller renders a template BY THE ACTION'S NAME, with no render call at
-- all. Without this edge the templates hang as a separate island with no entry
-- points whatsoever.
create view v_action_view_edges as
select c.path as from_path, '' as scope, v.path as to_path, 'action' as kind
from app_routes r
join app_controllers c on c.class_name = r.controller_class and c.path is not null
join code_refs v
  on v.kind = 'view_name'
 and (v.token = r.controller || '/' || r.action
      or right(v.token, length(r.controller) + length(r.action) + 2)
         = '/' || r.controller || '/' || r.action)
where r.controller <> '' and r.action <> '';

-- A model association is an edge too: a declared association leads to the class at
-- the other end.
create view v_assoc_edges as
select mf.path as from_path, '' as scope, tf.path as to_path, 'assoc' as kind
from app_associations a
join app_constants mf on mf.constant = a.class_name
join app_constants tf on tf.constant = a.target
where a.target is not null and tf.path <> mf.path;

create view v_code_edges as
select from_path, scope, to_path, kind from v_action_view_edges
union all select from_path, scope, to_path, kind from v_const_edges
union all select from_path, scope, to_path, kind from v_render_edges
union all select from_path, scope, to_path, kind from v_render_candidate_edges
union all select from_path, scope, to_path, kind from v_assoc_edges;
```

**Entry points and reachability.** An entry point is a place where the code starts
running AND the environment in which that happens: routed controllers in every
environment, background jobs in the environments where they are enabled, channel
services, and collector tasks via the set of services.

```sql
-- WHERE THE CODE RUNS, WITH A FALLBACK. Reachability is counted per place, and
-- the places come from the live service inventory — which a project with no ssh
-- to anything simply does not have. Then every cross join below yields NOTHING,
-- every entry point disappears, and the report says "reachable from an entry
-- point: 0" about a tree whose graph is perfectly fine. Measured in another
-- project: 19 JavaScript files, 11 import edges, zero reachable. One synthetic
-- place keeps the layer working, and the report says the places are not
-- configured instead of printing zeros.
create view v_places as
select distinct place from run_units
union
select 'local' where not exists (select 1 from run_units);

create view v_entry_points as
-- A routed controller is an entry point in EVERY environment where the web is up.
select c.path, p.place, 'controller' as kind, c.class_name as entry
from app_controllers c
join app_routes r on r.controller_class = c.class_name
cross join v_places p
where c.path is not null
group by c.path, p.place, c.class_name
union all
-- A background job only where it is enabled ('*' — everywhere).
select j.path, rp.place, 'job', j.class_name
from app_jobs j
cross join lateral unnest(j.places) as d(v)
join run_places rp on rp.env_id = d.v or d.v = '*'
where j.path is not null
union all
-- The same fallback for jobs: with no environments described, a scheduled job is
-- still an entry point — in the only place there is.
select j.path, p.place, 'job', j.class_name
from app_jobs j
cross join v_places p
where j.path is not null and not exists (select 1 from run_places)
union all
-- The channel service: it is up in every environment and was not an entry point —
-- so all the code reachable only from a channel lay outside the graph. The name
-- of the service is a SETTING (`idioms.channel_service_units`): it belongs to one
-- application, and an application that calls it something else would have had to
-- patch this view.
select c.path, u.place, 'channel', c.constant
from app_constants c
join run_units u on u.unit = any (array['channels-rpc']::text[])   -- from the configuration
where c.path like 'app/channels/%'
union all
-- JAVASCRIPT BUILD ROOTS COME FROM THE FACTS FIRST. A build root is an entry
-- point rather than a dead file: nothing imports it by construction, the bundler
-- starts from it. `js_entry` is what the bundler's own config names, and the
-- parse already records it; the path patterns are the fallback for a tree whose
-- config cannot be read, and they are a SETTING (`idioms.js_entry_paths`). Baked
-- in as one bundler's layout they made the whole front end of a project on
-- another bundler unreachable.
select f.path, p.place, 'pack', regexp_replace(f.path, '.*/', '')
from code_files f
cross join v_places p
where f.lang = 'js'
  and (exists (select 1 from code_refs e where e.kind = 'js_entry' and e.token = f.path)
       or f.path like any (array['app/javascript/packs/%']::text[]));   -- from the configuration

-- Background robots: a service -> a collector task -> the file where that task is
-- declared.
create view v_entry_rake as
select cr.path, u.place, u.task as scope, u.unit
from run_units u
join code_refs cr on cr.kind = 'task_entry' and cr.token = u.task
where u.task is not null;

create view v_reach as
with recursive seed as (
  select path, place from v_entry_points
  union select path, place from v_entry_rake
  union select e.to_path, s.place
         from v_entry_rake s
         join v_code_edges e on e.from_path = s.path and e.scope = s.scope
),
walk (path, place, depth) as (
  select path, place, 0 from seed
  union
  select e.to_path, w.place, w.depth + 1
  from walk w
  join v_code_edges e on e.from_path = w.path and e.scope = ''
  where w.depth < 9                  -- the ceiling: the graph converges at 5, the rest is room to grow
)
select path, place, min(depth) as depth from walk group by path, place;
```

**Reachability errs in both directions, and that has to be written into the view
itself.** Too wide: a reference to a constant is not yet a call, and a conditional
branch is indistinguishable from an unconditional one. Too narrow: a call on an
object is invisible to the graph, as is a dynamic call by name. Landing here means
"it looks reachable"; NOT landing here means nothing.

**What it is all for:**

```sql
create view v_break_here as
select r.token as table_name, rc.place, r.path, r.kind, rc.depth,
       array_to_string(r.lines, ',') as lines
from code_refs r
join v_table_presence tp on tp.name = r.token
join v_reach rc on rc.path = r.path
where r.kind in ('pg_table', 'pg_table_guess')
  and rc.place = any(tp.missing_in);
```

**Where the text in a substitution comes from.** Three roads, and all three are
candidates. The main thing here is **the strength of the link**: one matching name
is not to be trusted.

```sql
-- Unfolding detail into columns. `scopes` holds every scope where this same
-- substitution occurred: there is one row and the methods differ, and the scope of
-- the first one lies about the rest.
create view v_sql_holes as
select path, token as root, owner as context,
       detail->>'expr' as expr, detail->>'scope' as scope,
       array_to_string(array[detail->>'scope'] ||
                       coalesce(array(select jsonb_array_elements_text(detail->'scopes')), '{}'),
                       ', ') as scopes,
       coalesce((detail->>'blind')::boolean, false) as blind,
       coalesce((detail->>'fragment')::boolean, false) as fragment,
       detail->>'carrier' as carrier, detail->>'call' as call,
       detail->>'const' as const, detail->>'sql' as sql,
       count, lines
from code_refs where kind = 'sql_hole';

create view v_assigns as
select path, token as name, owner as scope, detail->>'value' as value,
       coalesce((detail->>'sql')::boolean, false) as is_sql,
       coalesce((detail->>'part')::boolean, false) as is_part,
       coalesce((detail->>'carrier')::boolean, false) as carrier,
       detail->>'op' as op, detail->>'from' as from_call, detail->>'const' as from_const,
       detail->'more' as more, count, lines
from code_refs where kind = 'assign';

-- Three DIFFERENT signs, and they must not be mixed up:
--   has_sql      — there is a query in the method's body (true of almost every model);
--   returns_sql  — the method RETURNS a whole statement;
--   returns_part — it returns a fragment. For a substitution that is the same thing.
create view v_defs as
select path, token as method, nullif(owner, '') as class_name,
       coalesce((detail->>'sql')::boolean, false) as has_sql,
       coalesce((detail->>'returns')::boolean, false) as returns_sql,
       coalesce((detail->>'returns_part')::boolean, false) as returns_part,
       coalesce((detail->>'singleton')::boolean, false) as singleton,
       coalesce(detail->>'visibility', 'public') as visibility,
       coalesce(array(select jsonb_array_elements_text(detail->'params')), '{}') as params,
       count, lines
from code_refs where kind = 'def';

create view v_sql_hole_source as
with h as (
  select *, nullif(regexp_replace(scope, '[#.][^#.]*$', ''), '') as class_name
  from v_sql_holes
),
d as (
  select *, (returns_sql or returns_part) as gives_sql from v_defs
)
-- something was assigned to the same name.
-- The strength of the match is a VALUE printed in the reports — 'файл' (file),
-- 'класс' (class), 'имя' (name only); the running tool prints them in its own
-- language, and yours can print them in yours.
select h.path, h.root, h.context, h.expr, h.scope, h.lines as hole_lines,
       'assign' as source_kind, a.path as source_path, a.scope as source_scope,
       a.value as source_value, (a.is_sql or a.is_part) as source_is_sql,
       case when a.path = h.path then 'файл'
            when regexp_replace(a.scope, '[#.][^#.]*$', '') = h.class_name then 'класс'
            else 'имя' end as match
from h
join v_assigns a
  on a.name = h.root
 -- A local variable is looked up ONLY in its own file: local `sql` variables from
 -- different files are not related in any way. @/$/CONSTANT — across the tree.
 and (a.path = h.path or h.root ~ '^[@$]' or h.root ~ '^[A-Z]')
union all
-- a method is called that — `h.call` is for `Repo.new.take_all`, where the root is a constant
select h.path, h.root, h.context, h.expr, h.scope, h.lines,
       'def', d.path, coalesce(d.class_name, ''), '', d.gives_sql,
       case when d.path = h.path then 'файл'
            when d.class_name = h.class_name then 'класс'
            when h.const is not null and d.path = c.path then 'класс'
            else 'имя' end
from h
left join app_constants c on c.constant = h.const
join d on d.method = coalesce(h.call, h.root)
union all
-- it was assigned by a call (`cond = build_cond`), and here is that method
select h.path, h.root, h.context, h.expr, h.scope, h.lines,
       'assign->def', d.path, coalesce(d.class_name, ''), a.value, d.gives_sql,
       case when d.path = h.path then 'файл'
            when d.class_name = h.class_name then 'класс'
            when a.from_const is not null and d.path = c.path then 'класс'
            else 'имя' end
from h
join v_assigns a on a.name = h.root and a.path = h.path and a.from_call is not null
left join app_constants c on c.constant = a.from_const
join d on d.method = a.from_call;
```

**If there is no source, say why.** A substitution whose root is a parameter of the
method it stands in: the text comes from the caller, and silence here reads as
"there is no source", although there is one and it lies one step up.

```sql
create view v_sql_hole_from_param as
select h.path, h.root, h.context, h.expr, h.scope, h.lines, d.method, d.params
from v_sql_holes h
join v_defs d
  on d.path = h.path
 and h.scope = coalesce(d.class_name, '') || case when d.singleton then '.' else '#' end || d.method
 and h.root = any(d.params);
```

**The observations — in three views: what was touched, with what exactly, and what
the static parse does not know.** The class of a column ("named in the selection"
against "rows are filtered by it") matters here just as much as in the static parse.

```sql
-- `days` is on how many days of the window this was seen. Without such a number
-- "it was touched in production" and "it was touched in production once in a
-- hundred days" are one statement, and those are different things.
create view v_runtime_table as
select t.name as table_name, r.place, sum(r.hits)::bigint as hits,
       count(distinct r.digest)::int as queries, max(r.day) as last_day,
       count(distinct r.day)::int as days
from sql_runtime r cross join lateral unnest(r.tables) as t(name)
group by 1, 2;

create view v_runtime_column as
select c.name as column_name, r.place, sum(r.hits)::bigint as hits,
       count(distinct r.digest)::int as queries, max(r.day) as last_day,
       count(distinct r.day)::int as days,
       bool_or(c.name = any(r.writes)) as written,
       bool_or(c.name = any(r.filters)) as filtered
from sql_runtime r
cross join lateral unnest(r.columns || r.filters || r.writes) as c(name)
group by 1, 2;

-- The observation window. Print it next to EVERY "not touched in production": on
-- its own that statement is unreadable — "not touched in one day" and "not touched
-- in a hundred days" differ in everything and look the same.
create view v_runtime_window as
select min(day) as first_day, max(day) as last_day,
       count(distinct day)::int as days, count(distinct place)::int as places,
       count(distinct host)::int as hosts, count(*)::int as skeletons,
       sum(hits)::bigint as hits,
       count(*) filter (where not parsed)::int as unparsed
from sql_runtime;

-- The table worked in production, and in the code not one parsed query names it:
-- either the name is assembled by interpolation (and then this is an answer to a
-- blind area) or it is touched by some other application.
create view v_runtime_unknown_table as
select rt.table_name, rt.place, rt.hits, rt.queries, rt.last_day
from v_runtime_table rt
where not exists (select 1 from code_refs c
                  where c.kind in ('pg_table', 'pg_table_guess') and c.token = rt.table_name);
```

**Environment keys and texts are a comparison of two lists as well.** In both cases
the classes decide more than the list does: without them the report comes out as a
wall.

```sql
create view v_env_usage as
select r.token as name, count(distinct r.path)::int as files,
       array_agg(distinct r.path order by r.path) as paths,
       count(distinct r.path) filter (
         where (r.path like 'app/%' or r.path like 'config/%'
                or (r.path like 'lib/%' and r.path not like 'lib/tasks/%'))
           and r.path not like 'spec/%')::int as app_files,
       count(distinct r.path) filter (
         where r.path like 'lib/tasks/%' or r.path like 'script/%')::int as task_files,
       array(select k.place from env_keys k where k.name = r.token order by k.place) as set_in,
       exists (select 1 from code_refs d where d.kind = 'env_default' and d.token = r.token) as has_default,
       exists (select 1 from code_refs f where f.kind = 'env_flag' and f.token = r.token) as is_flag
from code_refs r where r.kind = 'env_key' group by 1;

create view v_i18n_usage as
select r.token as key, count(distinct r.path)::int as files,
       array_agg(distinct r.path order by r.path) as paths,
       -- A key is sometimes a NAMESPACE: `t('about')` returns a hash, and the code
       -- walks it as a list. Without the prefix check such keys land in "there is
       -- no translation".
       (exists (select 1 from locale_keys k where k.key = r.token)
        or exists (select 1 from locale_keys k where k.key like r.token || '.%')) as in_store,
       (exists (select 1 from locale_keys k where k.key = r.token and k.lang = 'en')
        or exists (select 1 from locale_keys k where k.key like r.token || '.%' and k.lang = 'en')) as in_en,
       (select count(distinct k.lang) from locale_keys k where k.key = r.token)::int as langs
from code_refs r where r.kind = 'i18n_key' group by 1;

create view v_locale_orphan as
select k.key, count(distinct k.lang)::int as langs,
       array_agg(distinct k.file order by k.file) as files
from locale_keys k
where k.key <> ''
  and not exists (select 1 from code_refs r where r.kind = 'i18n_key' and r.token = k.key)
  and not exists (select 1 from code_refs r where r.kind = 'i18n_key' and k.key like r.token || '.%')
  -- The pattern has to be SELECTIVE: a pattern made of a single substitution
  -- matches any key and "explains" everything at once, that is, nothing.
  and not exists (select 1 from code_refs d where d.kind = 'i18n_dynamic'
                  and length(replace(d.token, '$1', '')) >= 4
                  and k.key like replace(d.token, '$1', '%'))
group by 1;
```

**Reduce the data measurement to a word.** Three numbers side by side are read
wrongly; a verdict is read rightly. The threshold "the default for almost everybody"
is needed because seventeen rows out of three million is also "nobody touched it".
(The verdicts are values printed in the reports; here they stand in the running
tool's own language — 'пусто' is "empty", 'всё по умолчанию' is "all default",
'умолчание почти у всех' is "the default for almost everybody", 'у новых не
заполняется' is "not filled for new rows", 'у новых почти не заполняется' is "almost
never filled for new rows", 'заполняется' is "being filled".)

```sql
create view v_column_fill as
select source, table_name, column_name, rows_total, rows_recent, filled, off_default,
       filled_recent, recent_by, measured_at,
       case when filled = 0 then 'пусто'
            when off_default = 0 then 'всё по умолчанию'
            when off_default is not null and rows_total > 0
                 and off_default < rows_total / 1000 then 'умолчание почти у всех'
            when rows_recent > 0 and filled_recent = 0 then 'у новых не заполняется'
            -- The share in a recent cohort ten times lower than the overall one
            -- means the mechanism is fading, and the overall count does not show
            -- that at all.
            when rows_recent > 0 and filled > 0
                 and filled_recent::numeric / rows_recent < (filled::numeric / rows_total) / 10
              then 'у новых почти не заполняется'
            else 'заполняется' end as verdict,
       case when rows_total > 0 then round(100.0 * filled / rows_total, 2) else 0 end as share
from column_fill;

-- An index nobody has ever read. Primary and unique ones do not count: they hold a
-- constraint rather than speed up a selection.
create view v_index_unused as
select source, table_name, index_name, size_bytes, since, measured_at,
       pg_size_pretty(size_bytes) as size
from index_usage
where scans = 0 and not is_primary and not is_unique;
```

**The blind areas go into a view of their own, and ONLY what is left unknown.** If a
name is assembled from a variable and the variable is assigned nearby, there is an
answer — keeping that in the ignorance count means lying about yourself. And "a piece
of a query" with human text is not a blind area: there is nothing there not to know.

```sql
create view v_blind as
select path, kind, token, count, lines, detail
from code_refs
where kind in ('sql_blind', 'hb_dynamic', 'scan_error')
  and detail->>'resolved' is null;

-- The name is assembled at runtime but was found by an assignment in the same file.
create view v_blind_resolved as
select path, token, detail->>'resolved' as table_name, lines, count
from code_refs where kind = 'sql_blind' and detail->>'resolved' is not null;

-- A piece of a query, or a phrase that begins with a keyword. NOT a blind area.
create view v_sql_piece as
select path, token as text, detail->>'error' as error, lines, count
from code_refs where kind = 'sql_piece';
```

**The documentation layer — two views whose logic is not obvious.** The rest (links,
paths, sections, names) are plain projections of their record kinds.

```sql
-- The class of a code block in a document. This is the layer's main view: without
-- the classes "it did not parse" was a false alarm over 137 blocks where fourteen
-- were real, and a false alarm devalues every other answer.
-- The class names are values printed in the reports: 'блок' (a block), 'набросок'
-- (a sketch), 'отрывок' (an excerpt), 'кусок запроса' (a piece of a query),
-- 'заплатка' (a patch), 'другой диалект' (another dialect), 'НЕ РАЗОБРАЛСЯ' (DID
-- NOT PARSE).
create view v_doc_code as
select path as doc,
       case kind
         when 'doc_code' then 'блок'
         when 'doc_code_sketch' then 'набросок'        -- …, <data centre number>: a human omission
         when 'doc_code_excerpt' then 'отрывок'        -- a break in the middle of a branch
         when 'doc_code_fragment' then 'кусок запроса' -- completed with a prefix
         when 'doc_code_patch' then 'заплатка'         -- a diff, not code
         when 'doc_code_dialect' then 'другой диалект' -- valid SQL of another engine
         when 'doc_code_broken' then 'НЕ РАЗОБРАЛСЯ'
       end as verdict,
       token as lang, owner as detail, lines,
       coalesce((detail->>'lines')::int, 0) as size
from code_refs
where kind in ('doc_code', 'doc_code_sketch', 'doc_code_excerpt', 'doc_code_fragment',
               'doc_code_patch', 'doc_code_dialect', 'doc_code_broken');

-- A document names a table that is in no schema snapshot. This is a QUESTION, not
-- a sentence: a dropped table looks like this, and so does one not created yet
-- (plans are full of proposals). So next to it — does the code touch it: if not,
-- the document is about the past or about the future rather than about today.
create view v_doc_table_unknown as
select n.name as table_name, count(distinct n.doc)::int as docs,
       array_agg(distinct n.doc order by n.doc) as docs_list,
       exists (select 1 from code_refs r
               where r.kind in ('pg_table', 'pg_table_guess') and r.token = n.name) as in_code
from (select path as doc, token as name from code_refs where kind = 'doc_table') n
where not exists (select 1 from v_tables t where t.name = n.name)
  and not exists (select 1 from db_routines d join v_current c on c.snapshot_id = d.snapshot_id
                  where d.name = n.name)
group by 1;
```

**The kinds of access to a column by name go into separate views.** They will be
needed by the "which fields are not used" report: the first two count as a use, the
third is a blind spot printed as a number.

```sql
-- The value is taken by a literal key. The table is known where it is visible WHICH
-- query filled the result row; where it is not visible the field is empty and the
-- strength of the link stays NAME. The report has to say which of the two cases it
-- is looking at.
create view v_column_value_read as
select token as column_name, nullif(owner, '') as table_name, path, lines, count
from code_refs where kind = 'key_read';

-- A name assembled by interpolation: `g$1`, `language$1_2`. A column of a series
-- cannot be found by a word — its name is not in the tree at all.
create view v_name_pattern as
select token as pattern, path, detail->>'expr' as expr, detail->>'scope' as scope, lines
from code_refs where kind = 'name_pattern';

create view v_column_key_pattern as
select token as pattern, path, detail->>'expr' as expr, detail->>'scope' as scope, lines
from code_refs where kind = 'key_pattern';

-- A variable key: `row[field]` in a loop over a list of fields. Which column that
-- is is unknown; keeping quiet is not allowed, otherwise "the value is taken
-- nowhere" is passed off as a fact where it simply is not visible.
create view v_column_key_dynamic as
select path, nullif(owner, '') as table_name, detail->>'expr' as expr,
       detail->>'scope' as scope, lines, count
from code_refs where kind = 'key_dynamic';

-- `select *` and what is REALLY taken out of that row: it turns an assumption into
-- a measurement. The star hides exactly one thing — an access whose key is a
-- variable. Such accesses come in two classes, and they must not be mixed:
-- `keys_dynamic` is exactly on a row of this table, `keys_dynamic_file` has an
-- unknown table but sits in the same files where this one is selected with a star
-- (in a file that never goes to the table, an access to its row is impossible).
-- Both zeroes together are what makes a proof.
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
```

**A column the table does not have in any environment is a breakage, not a finding
about something unused.** Filter out the system columns (`ctid`, `oid` are not in
the catalogue but exist on every table) and a substitution inside a name as well. A
"looks like" hint turns the report into a ready fix: three of our five findings were
a miss by one word.

```sql
create view v_column_blind as
select r.owner as table_name, r.token as column_name,
       case r.kind when 'pg_column_write' then 'запись' else 'чтение' end as mode,
       (select string_agg(n.column_name, ', ' order by n.column_name)
        from (select distinct column_name from v_columns where table_name = r.owner) n
        where n.column_name like left(r.token, greatest(length(r.token) / 2, 4)) || '%'
           or r.token like left(n.column_name, greatest(length(n.column_name) / 2, 4)) || '%') as looks_like,
       r.path, r.lines, r.count
from code_refs r
join (select distinct table_name from v_columns) t on t.table_name = r.owner
left join (select distinct table_name, column_name from v_columns) c
  on c.table_name = r.owner and c.column_name = r.token
where r.kind in ('pg_column', 'pg_column_write')
  and r.owner <> '' and c.column_name is null
  and r.token <> all (array['ctid', 'oid', 'xmin', 'xmax', 'cmin', 'cmax', 'tableoid'])
  and position('$1' in r.token) = 0;
```

(`mode` above is another printed value: 'запись' is "a write", 'чтение' is "a read".)

**A field list is bound to a table by the composition of its names, and that is how
it checks itself.** The list itself is as much a record of the index; repetitions in
its composition are merged but remembered separately, otherwise there is nothing to
check a repetition mechanically with.

```sql
create view v_column_lists as
select path, token as name, owner as scope,
       coalesce(array(select jsonb_array_elements_text(detail->'columns')), '{}') as columns,
       coalesce((detail->>'size')::int, 0) as size,
       coalesce(detail->'dups', '{}'::jsonb) as dups, lines
from code_refs where kind = 'col_list';
```

The share of matching names is the measure of confidence; require both a share and a
minimum number of matches, otherwise sets of words that happen to coincide with
column names crawl into the defects.

```sql
create view v_list_table as
select distinct on (path, name) path, name, table_name, matched, size,
       (100 * matched / greatest(size, 1))::int as share
from (select l.path, l.name, c.table_name, l.size, count(distinct u.col)::int as matched
      from v_column_lists l
      cross join lateral unnest(l.columns) as u(col)
      join (select distinct table_name, column_name from v_columns) c on c.column_name = u.col
      group by 1, 2, 3, 4) q
order by path, name, matched desc, table_name;

-- The defect names are printed values: 'повтор в списке' is "a repetition in the
-- list", 'пропуск в серии' is "a gap in the series".
create view v_column_list_defect as
select 'повтор в списке' as kind, l.path, l.name as list_name,
       t.table_name, d.key as column_name, (d.value #>> '{}')::int as times
from v_column_lists l
join v_list_table t on t.path = l.path and t.name = l.name
                   and t.share >= 60 and t.matched >= 5
cross join lateral jsonb_each(l.dups) as d(key, value)
-- Numeric and single-character "names" are not columns: the tree has a table with
-- columns `1`…`33` and another with `a`…`t`, and without filtering them out they
-- give a hundred false lines.
where d.key !~ '^[0-9]+$' and length(d.key) >= 3
union all
select 'пропуск в серии', t.path, t.name, t.table_name, c.column_name,
       (select count(*)::int from unnest(l.columns) as s(col)
        where regexp_replace(s.col, '[0-9]+$', '') = regexp_replace(c.column_name, '[0-9]+$', ''))
from v_list_table t
join v_column_lists l on l.path = t.path and l.name = t.name
join (select distinct table_name, column_name from v_columns) c on c.table_name = t.table_name
where t.share >= 60 and t.matched >= 5
  and c.column_name <> all (l.columns)
  and c.column_name ~ '[0-9]$'
  and regexp_replace(c.column_name, '[0-9]+$', '') <> ''
  and (select count(*) from unnest(l.columns) as s(col)
       where regexp_replace(s.col, '[0-9]+$', '') = regexp_replace(c.column_name, '[0-9]+$', '')) >= 2;

-- The journal of checked findings (VI.3): a verdict together with its FRESHNESS.
-- The state is computed here and only here — repeating this rule in a second place
-- means letting the two drift apart.
-- The states are printed values: 'без файла' is "no file", 'файла нет' is "the file
-- is gone", 'свежий' is "fresh", 'устарел' is "stale".
create view v_finding_verdict as
select v.kind, v.subject, v.verdict, v.checked, v.reason, v.path, v.checked_at, v.git_sha,
       case
         when v.path is null then 'без файла'   -- never ages, and that has to be said out loud
         when f.path is null then 'файла нет'
         when f.sha = v.file_sha then 'свежий'
         else 'устарел'                         -- the file was edited: the finding returns to the report
       end as state
from finding_verdicts v
left join code_files f on f.path = v.path;

-- What gets filtered out of the reports. Only "false" and only while the verdict is
-- fresh.
create view v_finding_hidden as
select kind, subject, reason, checked, checked_at
from v_finding_verdict
where verdict = 'ложная' and state <> 'устарел';

-- The reliability of a class: how much to trust a NEW finding of this kind. (Part V
-- continues — the views of the stylesheet and JavaScript layers come after this
-- block.)
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
```

**Stylesheets: "what keeps a file alive" is a CASE, and every one of its branches has
once saved a live file from the removal list** (IV.18). The order of the branches
matters: the class is assigned by the first match, so "vendored" and "served as a
file" stand before the ways of being included.

(The classes are printed values: 'поставляемое' is "vendored", 'отдаётся как файл' is
"served as a file", 'вход сборки' is "a build entry", 'подключён @import' is "included
by @import", 'подключён из javascript' is "included from javascript", 'упомянут в
шаблоне' is "mentioned in a template", 'КАНДИДАТ НА СНЯТИЕ' is "A CANDIDATE FOR
REMOVAL".)

```sql
create view v_css_file as
select f.path, f.bytes,
       (select count(*) from code_refs c where c.kind = 'css_class' and c.path = f.path)::int as classes,
       (select count(*) from code_refs i where i.kind = 'css_import' and i.path = f.path)::int as imports
from code_files f where f.lang = 'css';

create view v_css_edges as
select path as from_path, '' as scope, token as to_path, 'css_import' as kind
from code_refs where kind = 'css_import';

create view v_css_unreachable as
select f.path, f.bytes, f.classes,
       case
         when f.path like '%/vendor/%' or f.path like 'vendor/%'
           or f.path like 'node_modules/%' then 'поставляемое'
         when f.path like 'public/%' then 'отдаётся как файл'
         when exists (select 1 from code_refs e where e.kind = 'js_entry' and e.token = f.path)
           then 'вход сборки'
         when exists (select 1 from v_css_edges e where e.to_path = f.path) then 'подключён @import'
         -- A stylesheet is pulled in by JAVASCRIPT too: `import
         -- '../css/uppy_upload.css'` in a bundle root, and the bundler emits the
         -- CSS as a side output. Without this branch a live file lands among the
         -- candidates for removal.
         when exists (select 1 from code_refs j
                      where j.kind = 'js_import' and j.token = f.path) then 'подключён из javascript'
         when exists (select 1 from code_refs r where r.kind = 'asset_ref' and r.token = f.path)
           then 'упомянут в шаблоне'
         else 'КАНДИДАТ НА СНЯТИЕ'
       end as kind
from v_css_file f;
```

**The chain "contour → bundle → build entry → `@import` → file" is a recursive view
plus one naming convention, said out loud.**

```sql
create view v_pack_entry as
select detail->>'pack' as pack, token as entry, path as config, 'ключ конфига' as how
from code_refs where kind = 'js_entry' and detail->>'pack' is not null
union
-- BY A NAMING CONVENTION: an entry assembled in the config out of parts
-- (`path.join(root,'app','javascript','x','x.css')`) has no key at all, while the
-- template asks for the bundle by the name `x`. The bundle's name coincides with
-- the entry file's name without its extension — that is what we link by. Without
-- this a contour turns out to have NOT ONE style of its own, and the view answers
-- "there is no rule in the contour" honestly and uselessly.
-- ('ключ конфига' is "a config key", 'по имени файла' is "by the file name".)
select r.token as pack, e.token as entry, e.path as config, 'по имени файла' as how
from code_refs e
join code_refs r on r.kind = 'pack_ref'
               and r.token = regexp_replace(regexp_replace(e.token, '.*/', ''), '\.[a-z]+$', '')
where e.kind = 'js_entry' and e.detail->>'pack' is null;

create view v_pack_css as
with recursive reach as (
  select e.pack, e.entry as path from v_pack_entry e
  union
  select r.pack, d.to_path from reach r join v_css_edges d on d.from_path = r.path
)
select pack, path from reach
where exists (select 1 from code_files f where f.path = reach.path and f.lang = 'css');

create view v_pack_ref as
select r.path, r.token as pack,
       case
         when r.path like 'app/views/layouts/%'
           -- `split_part` instead of a regular expression, deliberately: a
           -- backslash in the pattern did not survive two layers of quotes on its
           -- way to SQL, and the contour's name came out EMPTY — the view silently
           -- returned zero rows.
           then split_part(regexp_replace(r.path, '.*/', ''), '.', 1)
         when r.path like 'app/views/%'
           then split_part(regexp_replace(r.path, '^app/views/', ''), '/', 1)
         else 'вне шаблонов'
       end as contour
from code_refs r where r.kind = 'pack_ref';
```

**A class: its declaration, its consumers, a pattern and a verdict.** There is one
verdict per name, and "matches a pattern" is a class of its own rather than
"mentioned": it is not proof of use, but it is not grounds for removal either.

(The verdicts here read: 'поминают' — "it is mentioned", 'подходит под узор' —
"matches a pattern", 'файл никто не подключает' — "nobody includes the file",
'поставляемый стиль' — "a vendored stylesheet", 'НЕ ПОМИНАЕТ НИКТО' — "MENTIONED BY
NOBODY"; and for the contour: 'правило в контуре есть' — "there is a rule in the
contour", 'паки контура не сопоставлены входам' — "the contour's bundles are not
matched to entries", 'правило есть, но в другом контуре' — "there is a rule, but in
another contour", 'правила нет ни в одном НАШЕМ стиле' — "there is no rule in any of
OUR stylesheets". 'разметка' is "markup".)

```sql
create view v_css_class as
select c.path, c.token as name, c.lines,
       (select kind from v_css_unreachable u where u.path = c.path) as file_kind
from code_refs c where c.kind = 'css_class';

create view v_css_class_use as
select token as name, 'разметка' as how, path, lines from code_refs where kind = 'html_class'
union all
select token as name, '@apply' as how, path, lines from code_refs where kind = 'css_apply';

create view v_css_class_pattern as
select token as pattern, detail->>'glob' as glob, path, lines
from code_refs where kind = 'html_class_pattern' and detail->>'glob' is not null;

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

create view v_css_class_contour as
with contour_pack as (
  -- A CONTOUR is only one whose chain is provable: the layout of the same name
  -- names a bundle. A directory of templates is not a contour (it is rendered
  -- under a layout chosen at runtime), and attributing styles to it means
  -- answering with an untruth. My first version invented five such "contours".
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
```

**JavaScript: a class for the file instead of the single word "unreachable", and a
call as a lead** (IV.19). In the tool itself `v_js_unreachable` has one more column,
"mentioned in a document" — it pulls in the documents layer and is omitted here so
that the block stays self-contained.

(The classes read: 'корень сборки' — "a build root", 'самостоятельный скрипт' — "a
standalone script", 'отдаётся как файл' — "served as a file", 'поставляемая
зависимость' — "a vendored dependency", 'корень из конфига сборки' — "a root from the
build config", 'объявление типов (читает tsc)' — "a type declaration (read by tsc)",
'прогон тестов' — "a test run", 'настройка сборки' — "a build setting".)

```sql
create view v_js_edges as
select path as from_path, '' as scope, token as to_path, 'import' as kind
from code_refs where kind = 'js_import';

create view v_js_unreachable as
select f.path, f.bytes,
       case
         when f.path like 'app/javascript/packs/%' then 'корень сборки'
         when f.path like 'script/%' then 'самостоятельный скрипт'
         when f.path like 'public/%' then 'отдаётся как файл'
         when f.path like 'vendor/%' then 'поставляемая зависимость'
         when exists (select 1 from code_refs e
                      where e.kind = 'js_entry' and e.token = f.path) then 'корень из конфига сборки'
         -- Three classes of file that NOBODY imports and that are nevertheless
         -- alive: they are read not by the code but by a tool. Without them eight
         -- such files stood as candidates for removal and would have hidden a real
         -- dead file.
         when f.path like '%.d.ts' then 'объявление типов (читает tsc)'
         when f.path like '%.test.ts' or f.path like '%.spec.ts'
           or f.path like '%.test.js' or f.path like '%.spec.js' then 'прогон тестов'
         when f.path like '%.config.ts' or f.path like '%.config.js'
           or f.path like '%.config.mjs' then 'настройка сборки'
         else 'КАНДИДАТ НА СНЯТИЕ'
       end as kind
from code_files f
where f.lang = 'js'
  and not exists (select 1 from v_js_edges e where e.to_path = f.path);

create view v_js_func as
select path, token as name, nullif(owner, '') as scope, lines
from code_refs where kind = 'js_func';

create view v_js_call as
select path, token as name, lines from code_refs where kind = 'js_call';

-- "Nobody calls it" here is the BEGINNING of the check, not its conclusion: the
-- export and the file's class ride next to it, because a function is also passed
-- by value and called from a script.
create view v_js_func_unused as
select f.path, f.name, f.scope,
       exists (select 1 from code_refs e
               where e.kind = 'js_export' and e.path = f.path and e.token = f.name) as exported,
       (select u.kind from v_js_unreachable u where u.path = f.path) as file_kind
from v_js_func f
where not exists (select 1 from v_js_call c where c.name = f.name);

-- A library: we do not go inside, we count the mentions of the import BINDING.
create view v_js_package_use as
select b.owner as package,
       count(distinct b.path)::int as files,
       array_agg(distinct b.token order by b.token) as bindings,
       sum((b.detail->>'mentions')::int)::int as mentions
from code_refs b where b.kind = 'js_binding' and b.owner <> ''
group by 1;
```

---

# Part VI. The reports

Rules common to every report. Breaking any of them kills trust in the tool faster
than any error in the parse.

**A fact, a candidate and a guess go in different sections.** Not in one list with a
marker, but in genuinely different sections with different headings.

**Name the strength of the link on every line.** `file` / `class` / `name`. The last
is noise; either do not print it or print it as a separate line: "N more links found
by a name match only — these are not findings".

**Do not expand a frequent name.** If a name is declared nine times in the tree and
has a thousand six hundred "calls", those are somebody else's calls. Print "the name
is frequent (N declarations), a summary means nothing" rather than the numbers.

**An empty list is an answer, and it is printed in words.** "It is not called by name
anywhere — not from code, not from templates, not through a dynamic call with a
literal name; what remains is an interception of accesses and a name assembled at
runtime." Silence is not an answer.

**"Dead" always comes together with "what holds it".** Next to "there are no calls"
print the mentions outside calls: tests, inventories, documents, configurations,
comments. Our very first finding was like that: the method is called nowhere, but its
line has an exception registered in a guard test. They have to be deleted as a pair.

**Split the result by the strength of the conclusion.** "Mentioned by nothing — can be
removed on its own" and "held by mentions — remove as a pair". The first is a safe
list, the second is for examination.

**Measure in more than counts.** "Two hundred dead methods" is a number with no
scale. Two hundred one-line wrappers and two hundred hundred-line parsers are
different conversations. Take a method's boundaries from the parser rather than by
counting to the next declaration: between methods lie comments, and they belong to
what is below.

**A latch instead of a zero.** For architectural rules: this many violations are
tolerated today, and the report keeps quiet until the number grows. The same technique
formalises the counter of an unfinished migration — the number must only fall.

**Numbers age.** Print the command that recomputes them next to them, and add the
caveat "the numbers are as of the day of the edit".

---

## VI.0. Latency is a property of the tool, not of its wrapping

This chapter should have come first, because everything else depends on it. A tool
that answers in six seconds is only asked when the question is knowingly structural;
in every other case a person (and an agent) reaches for grep — and uses a habit rather
than a tool. We discovered this late and measured it: `where` on a table answered in
**6.5 s**, while `git grep` over the same tree took **0.24 s**. And the query to the
index database itself took **0.04 s**. That is, the index was two hundred times faster
than grep, and the wrapping around it seven hundred times slower.

The breakdown by terms turned out to be more instructive than the numbers themselves —
not one of them was "the price of the index":

| where it went | how much | what it was |
| --- | --- | --- |
| loading the application | 3.1 s | the reports do not need it: this is SQL to a local database |
| hashing all the files | 1.5 s | paid on every command with zero edits |
| the join by view names | 2.3 s | the condition was not hashable, so a nested loop ran |
| the query itself | 0.04 s | |

**Loading the framework.** A report is SQL to your own database; the framework is not
needed there for anything. A separate entry point that loads only the database layer
and the driver costs 0.4 s instead of 3.1. What stays on the application are exactly
the tasks that cannot do without it: those that ask the framework itself for facts
(routes, models, autoloading) and those that go to the application's database through
its connection. The precondition for this: there must be no references to the framework
inside the tasks — for us `Rails.root` in seventeen places was replaced by our own
`Xref.root`, which falls back to the working directory without the framework.

**Catching the index up.** Computing the checksum of every file on every command is 1.5
s that is almost always spent for nothing. Put a gate by modification time before the
hashing: walking the same files with `stat` costs 0.018 s, eighty times cheaper.
**Modification time is not proof in either direction:** if it matches we trust the
previous checksum, if it differs we compute the checksum and compare that. A file
rewritten with the same content is not re-parsed.

This gate breaks IN THE DANGEROUS DIRECTION: missing a changed file means answering
from the old content while looking fresh. So the decision is lifted into a separate pure
function (with no file system) and closed by a spec that checks both the saving and its
safety — that we do not hash what we need not AND that we do not miss what has changed.

**Queries.** Two places where a report was slow not because of volume but because of
the form of a condition, and both are cured the same way:

* `v.token = r.token or right(v.token, length(r.token)+1) = '/' || r.token` cannot use
  an index at all — the planner goes for a nested loop and throws away 4.8 million
  pairs. Add **a first tier on the last segment of the name**: if the full name ends
  with `/` plus what is sought, the last segments are necessarily equal. That tier is
  hashable, and the original condition stays as a filter. The same answer, thirty-five
  times cheaper;
* three rules about translation keys, written with `LIKE` over all 102,648 keys of the
  store, cost 94 s. The same rules via **a decomposition of the key into dotted
  prefixes** (a join on equality) take 0.6 s. Plus two techniques: compute the tiers IN
  ORDER (the expensive tier only for what the cheap ones did not cover) and reduce both
  sides to distinct values BEFORE the join (we had 102,648 rows for 8,959 keys and
  11,087 records for 2,699 names — joining them "as they lie" gave 179,139 pairs instead
  of 2,699).

**After any such change, compare the answer with the old definition by selecting both
ways.** Not "it looks alike" and not "the same number of rows", but `except` in both
directions: for us both rewrites gave zero divergence, and only that allows them to be
released.

**Compute a heavy view once per command.** The reports ask several questions of one
view; a temporary table lives until the end of the connection, that is, exactly one
command. And **what can be computed during the parse should not be computed in the
report**: the length of a method was known to the parser, while the dead-methods report
re-read and re-parsed every file with a finding three times over.

The result: 6.5 s → 1.3 s per query, 26 s → 2.5 s for the graph walk, 318 s → 7.7 s for
the texts report. This is not cosmetics — it is the difference between "the tool gets
used" and "the tool exists".

---

## VI.0.1. Text search: as a wrapper, not as an index of your own

Sooner or later the question comes up: the tool answers structural questions, and
does not answer "where does this string occur" at all — and because of that it stays
a second tool next to grep. Our layer of candidates by word knew 2,305 names (only
names from the database), so any question about a comment, an address, the text of an
error or a settings key went to grep.

The temptation is to build a table of strings and a trigram search. **Do not do
that.** A second index would age separately from the first, would need its own
catch-up and its own freshness check — that is, exactly the disease the tool is built
to cure.

The right move is **a wrapper over a ready-made search**: it is fresh by
construction, needs no maintenance, and the tool adds to the findings what the search
does not know — whether the file is reachable from production and from what depth, who
calls it, which tables it touches, how many blind spots it contains, whether it is
rendered in the live logs. "Instead of grep" does not mean "faster than grep", it
means **"grep plus meaning"**.

Three things worth knowing in advance:

* **the fast search may be unavailable**, and an answer still has to be given. A
  fallback path is not an error; but the report has to say which one it took: the
  fallback has a different price (for us, 271 patterns over 196 MB — 0.9 s against 36
  s);
* **compare the two engines on one question.** Ours diverged by five findings out of
  67, and diverged silently: one of them does not enter directories with a dot by
  default, and tracked files live there;
* **the most expensive trap**: with no explicit path, `rg` with standard input not
  coming from a terminal reads STANDARD INPUT, finds nothing and exits with "no
  matches". By hand the same command answered with 1,282 lines. An empty answer would
  have been read as "this is not in the tree".

And a small thing that changes the usefulness of an answer more than it seems:
**print the text of the found line**. A line number says WHERE, and the decision is
made from WHAT is there — otherwise the answer sends you off to open the file. The
line that opens a heredoc has no content of its own: take the next two, otherwise half
the answers about queries stay contentless.

**The same search cures your own sweeps over the tree.** The reports ask three
questions that used to be answered by a sweep over 196 MB in Ruby: "who mentions these
names at all" (33 s), "which route helpers exist in the tree" (11 s) and "which paths
are written as strings" (6 s). All three by search: 1.3 s, 0.9 s and 0.4 s. The whole
"unused" report went from 80–140 s to 15 s, and that is the difference after which
people start using it.

The technique without which the replacement lies: **the search is a PREFILTER, and the
expression decides.** The search looks for the stem of a name (`part_present?` →
`part_present`) and as a whole word, that is, it knowingly finds more than is needed,
while the exact rule is applied to the found lines by your own parse. Otherwise the rule
has to be repeated in somebody else's regular-expression dialect — and it will drift.

Four divergences between the search and the full sweep, each found by comparing sets
rather than by reasoning — and each of which would have cost the report's credibility:

- **the case-insensitivity flag does not live in the expression's text.** `source` does
  not carry it, and the search found 6,064 paths instead of ten thousand — silently;
- **the search looks line by line**, so a match at the START of a line has no preceding
  character: without `^` in the pattern 902 paths were lost;
- **the search goes where the sweep did not** (vendored dependencies, gem
  documentation) — the same exclusions are needed, otherwise other people's code
  crawls into the answer;
- **the sweep does not read files above a threshold, and the search does not read
  binary ones.** For us that is 412 found in addition (machine inventories larger than
  4 MB — the side where an error is dangerous: "nobody mentions it" reads as "it can be
  removed") against 863 lost, and all 863 turned out to be rubbish from PNGs: NOT ONE of
  them matched a route of the application. That is exactly how it has to be checked —
  not "how much diverged" but "does the divergence change the answer".

---

## VI.1. How to check that the tool is not lying

A report that looks right proves nothing. For every capability it is useful to have a
**control experiment** — one after which the tool is obliged to say out loud that it
does not know something. Three experiments worth running first; every one of them
failed for us once.

**A schema change with the source file unchanged.** Add a column to the database, take
the schema and do NOT touch a single code file. The tool must notice and sweep the tree
again. If incrementality rests on the file's checksum alone, it will not notice: the
checksum is the same, while the candidate layer and the binding of columns to models are
already different. What has to be checked is not the fact of the re-parse but its
effect: the new column's name must appear in the index. For us it appeared as four
records that would never have existed before the change.

**A disabled parser.** Hide the SQL parser and ask the same question. The answer must
differ from the answer under a full parse. If it is the same, your zero findings are
indistinguishable from "we did not look", and that is the worst kind of lie: it is
invisible.

**A new forbidden access.** Lower an architectural rule's latch by one and run the
check: it must shout. The experiment is conveniently done by editing the configuration
in memory, without touching the file.

Two consequences for the reports:

- **the state of the index is part of every answer.** One line in the header: how many
  files, how old the schema snapshots are, how many blind spots. As a separate loud line
  — if the snapshots are more than a day old, if a fetch from a source failed, if the
  tree was parsed under different generations of the schema, if the parser was missing;
- **an empty answer explains itself.** "A zero under a full parse is an absence" and "a
  zero under an incomplete parse may be ignorance" are different statements, and they
  have to be printed in different words.

## VI.2. From the task to the files, not from a file

The report "what to read before editing this file" starts in the middle: to ask it you
already have to know where to look. The first question has to be a different one —
**from the task**: take a route, an action, a table, a file or just a word and produce
the order **entry points → map → sources**, not a list of files jumbled together.

Four blocks, in this order:

1. **the entry points** — routes with their request counts from observation (not every
   route matching by name), tables with the environments missing them, files matching by
   name;
2. **read first** (step 1 along the reference graph) and **next** (step 2);
3. **the tables of the area that are missing somewhere** — so that you read the sources
   already knowing where this will fail;
4. **how many blind spots and holes in queries there are in the area** — the honest
   measure of how much of the area the tool itself did not understand.

Two things make such a report useful rather than merely long.

**Laying the step out by component, code before templates.** Without it step 1 gives
nine dozen files and shortens nothing. With it one can see: what has to be read is one
controller, nineteen files of the service layer and eight models, while six dozen
templates fold into four lines with the remainder "and N more". The order of the
components is the same rank of layers as in the architectural rules.

**A task about a column is not a task about a table.** If the input is `table.column`,
take as the starting files those whose query contains that very column, and descend to
the table only when nothing was found for the column. Otherwise forty files touching a
wide table inflate the area tenfold — and the report, whose job is to shrink it, does
the opposite. The column, meanwhile, lies in the index as a token with the table as its
owner rather than as the string `table.column`: it has to be looked up as a pair.

**The count of distant dependencies.** Print how many files arrived ONLY along the
reference graph and contain not one word of the task in their path: by file name they
cannot be found. Exclude the starting files from the count — a search finds those too,
and otherwise the number praises the tool for somebody else's work. Take the task's
words separately: `users.email` is two words, and there is no path containing the whole
thing with the dot, so the count would come out "about everything". This is a measurable
form of the question "does the map find a distant dependency known in advance", and the
answer to it is not rhetorical: on one of our tasks there are 156 such files out of 243,
and among them are files whose names do not share a single letter with the task —
because the data lies in another store, and the task's name shows nothing of that.

## VI.3. The journal of checked findings

The most expensive measurement in all the time spent on this tool, and it is not about
the code.
Seven classes of finding, checked against the first source one after another, over
two days:

| class | the report said | real | false |
| --- | ---: | ---: | ---: |
| broken examples in documents | 137 | 7 | **95 %** |
| broken links | 632 | 15 | **98 %** |
| `rewrite … last` | 25 | 2 | **92 %** |
| missing translations | 22 | 6 | 73 % |
| accesses to a column that does not exist | 13 | 4 | 69 % |
| dead Stimulus controllers | 3 | 1 | 67 % |
| "used by nobody" (a quick regular expression) | "more than a dozen" | 1 | — |

This is not sloppiness in the parser — it is **a property of a new layer**. In a
layer that has only just appeared there are two or three times more false findings
than real ones, and they become fewer exactly as fast as each one is checked against
the source and the filtering rule is rewritten. A hundred and thirty-seven broken
examples became seven after six filtering classes (a sketch, an excerpt, a patch, a
piece of a query, another dialect, a lying language label) — and not one of those
classes could have been thought up in advance; they are visible only on the findings.

Hence three conclusions, and all three are about how the tool is built rather than
about diligence.

**The check has to be stored next to the finding.** Each of those seven checks cost
half an hour of reading the first source, and all the knowledge stayed in a commit
message. So the index holds a table of verdicts: the class, the subject, the verdict
(`real`/`false`), what it was checked with, why, and the file's SHA at the moment of
the check.

**What has been judged false does not enter the report again.** Otherwise it gets
re-checked every time, and people learn to leaf past the report — and then a real
finding drowns not in the tool's noise but in the reader's habit. The filtering goes
by ONE expression of the subject, written in one place (`Xref::Verdicts::KINDS`): let
two spellings drift apart and the verdict silently stops recognising its finding.

**The reliability of a class is printed next to it.** "13 checked, 9 false (69 %)" is
the answer to a question the tool did not know how to ask: how much to trust a NEW
finding of this kind. Without that number every finding reads as equally weighty, and
they are not equal: in one class every third is wrong, in another nineteen out of
twenty.

The journal has exactly one danger, and it is of the same kind as the gate before
hashing: **a "false" verdict hides a finding, that is, it can conceal a real problem
that appears later in the same place.** So the verdict is bound to the file's SHA: the
file changed — the verdict is **stale**, and the finding is back in the report with a
mark. The classes with no file at all (a translation key, an index in the database, a
table name from a document) never age, and the report has to say that out loud — for us
such a verdict is printed in words as "removed from the reports FOR GOOD".

And the last thing, without which the journal turns into a way of hiding what is
inconvenient: **the report has to show what it has hidden.** `bin/xref findings
<class>` prints three lists — the open findings, those checked and judged false (with
the reason and the date) and those checked and confirmed. A report that silently removes
findings is more dangerous than a report with noise: the reader knows about noise and
does not know about silence.

```sh
bin/xref findings                     # the classes: open / checked / the false share
bin/xref findings column              # the list of subjects in a class
bin/xref verdict column "app/models/order.rb:rewards.points" \
         ложная "the method was removed in 2024, nobody can call it" схемой
```

The verdict word also accepts `false`/`wrong` and `real` in English; the "checked
with" word is one of the closed list in the record contract (by execution, by the
schema, by data, by logs, by a spec, by eye) — in the running tool those words are
Russian, and `ложная`/`схемой` above are "false"/"by the schema".

**The register of classes grows together with the layers, and that is the main reason
to keep it as a single list.** We have 17 classes (from "the code goes to a column
that does not exist" to "a class is declared and nobody mentions it"), 37 checks in
eight of them, 22 findings hidden as false. A new layer adds a class, not a filtering
mechanism of its own: add a line to the register and the class immediately has a
journal, a false share, and "the report shows what it hid".

And three things learned on the journal itself:

- **an anchor is sometimes incomplete, and that has to be printed.** A translation key
  has no file; the anchor taken is the first calling file, but the key is called from
  several places, and editing the second one will not cancel the verdict. An incomplete
  anchor is better than no anchor — but only if its incompleteness is stated;
- **editing the filtering rule beats a verdict** when the findings share a cause: three
  of the seven unparsed examples in documents turned out to be human notes — that is
  three new filtering classes and three examples in the specs, not three verdicts. A
  verdict is for an isolated case;
- **a silent no-op in the verdict write itself.** In somebody else's copy of the tool
  the write command printed "remembered" and wrote nothing to the database (the class
  names had drifted apart). So writing a verdict must check ITS OWN EFFECT: count the
  findings before and after and say whether the number changed.

# Part VII. The rules that cost more than the code

If one section of this specification is to survive, let it be this one. Every item
once cost an incident, lost data or a false report.

1. **A tool that does not name its blind spots lies silently.** The absence of a record
   reads as "there are no links". Silence is not an answer; "I do not know" is.
2. **The absence of proof is not proof of absence.** A day of logs proves a screen is
   in use and says nothing about its being dead. Write that straight into the report,
   next to the numbers.
3. **Check that an edit took effect.** If after tightening a condition the number in
   the report has not changed — suspect the condition was not applied.
4. **A whitespace-squeezing function eats SQL comments.** Collapsing a query into one
   line sweeps everything up to the end of the query into `--`: a condition is silently
   switched off, the query stays valid and runs. Put a comment to such a query as a
   comment of the language ABOVE the text, not inside the SQL.
5. **An empty answer does not overwrite what was collected.** Losing an update is
   cheaper than losing data.
6. **Do not require tooling dependencies from code that is loaded in production.** The
   SQL parser is needed only by a developer; if its `require` stands in a file the
   application loads at boot, a production image without that dependency will not come
   up. Load it on demand and survive its absence: without the parser the index is
   merely poorer.
7. **Sorting depends on the locale.** The first comparison of two lists of names
   produced rubbish — the names turned out to be on both sides at once. Any comparison
   runs with a fixed locale.
8. **A shard prefix is not a table.** Before trusting the line "the table is absent in
   this environment", check whether it is a prefix: the code may be going to `t_0…t_N`,
   which exist everywhere, while the index holds the guess `t`.
9. **One name — one row per file.** A row per occurrence gives hundreds of thousands of
   rows and exactly as much use as one.
10. **Invalid UTF-8 comes out of the parser.** Scrub every text, otherwise the write to
    the database dies on a random file.
11. **An interrupted parse leaves no halves.** The delete and the insert of a file's
    records go in one transaction.
12. **Tests for the parser are not a luxury.** The rules are subtle and break silently:
    the report goes on being printed, just with different numbers. Fifty-odd examples on
    fixtures, each of which closes a mistake that has already happened.
13. **A shared working directory.** If several processes work in the tree, commit by
    path and never stash your changes.
14. **Bytes from outside are not yet text.** The output of a command, a value from the
    environment, an argument and a log line are stamped with the LOCALE's encoding.
    Without it that is US-ASCII, and the first non-Latin letter kills `split`, `match?`
    or `format` — what dies is not one finding but the WHOLE command, and it reads as
    "the tool is broken". Two subtleties, each of which cost a check:
    `Encoding.default_external` does NOT fix the environment or the arguments (those are
    stamped by the locale, and it does not change after the process starts — the cure is
    restarting the process with `LC_ALL=C.UTF-8`), and changing the label does not fix
    the CONTENT — a genuinely broken byte stays, and scrubbing is needed. An entry point
    that does not load the application's framework does not get its encoding settings
    either: that is how two of our twenty-seven commands silently did not work, and it
    was found by experiment (`env -u LANG …` on each of them) rather than by reading.
15. **A `rescue` around a file walk hides not an error but data.** The classic form:
    `File.foreach … rescue ArgumentError; next`. One broken byte in the middle of a file
    — and the rest of the file is unread, with a green answer. On this an error monitor
    of ours answered "not a single one", having read the log up to the first such byte.
    If swallowing is unavoidable, print a count of what was skipped.
16. **In a new layer there are more false findings than real ones — two or three times
    more.** Measured over seven classes: 137 broken examples → 7, 632 broken links → 15,
    25 `rewrite` defects → 2, 22 missing translations → 6, 13 accesses to a column that
    does not exist → 4, 3 dead controllers → 1. Not one of the filters that cut those
    numbers could have been thought up in advance — they are visible only on the
    findings. Therefore: a finding is checked against the first source BEFORE it
    reaches a human in a report; the result of the check is stored next to the finding
    rather than in a commit message; and the share of false ones in a class is printed
    next to it — otherwise every finding reads as equally weighty, and they are not
    equal. In detail — VI.3.
17. **A layer that is not in the sweep does not keep quiet — it LIES.** A false finding
    is noise; a missing file extension is something else: the parser sees half of a
    chain and confidently reports a defect. In a TypeScript project `.ts/.tsx` were not
    on the extension list, and the report produced six findings of "the controller is
    not registered" and "there is no such method" with the registration and the methods
    existing. The sign of such a breakage is a ZERO in a layer's counter (zero
    controllers, zero keys from templates, zero classes): a zero in the self-diagnosis
    is the first thing to check, it is almost never the truth.
18. **Say a link by CONVENTION out loud.** Where there is no reference and a link is
    needed anyway, it has to be derived from an agreement: the bundle's name coincides
    with the entry file's name, a helper is included by the framework by the directory's
    name, a cron job is called after the class. Such a link is neither a fact nor a
    guess but a third thing: it is true as long as the agreement is kept. Print "by the
    file name" next to the line, and then a divergence reads as a divergence rather than
    as a breakage of the tool.

---

# Part VIII. The tests: what to assert

Fixture examples for the parser. The list is the minimum set below which the tool
starts lying silently. We have 291 of them in twenty files, they run in 2.5 s, and the
very first run found a double write because of which the call count was twice too
high. There is one selection rule: **an example comes from a mistake that happened**,
not from a wish to cover a branch. So every example has a comment saying "what it once
caught" — without that, in a month it is unclear whether it may be edited.

**Parsed SQL:** the table and the column are extracted; the column is bound to the
table; a key inside a JSON field is extracted together with the field.

**Substitution:**
- a table name assembled at runtime does NOT enter the facts; it enters the blind
  areas; the prefix enters the guesses;
- the record has an expression, a root and a position in the query;
- `in (…)` is recognised for the second element of the list as well, not only for the
  first;
- a value, quotes and a whole condition are told apart;
- strings glued by a line continuation parse as ONE query: the table is found, there are
  no blind areas, the substitution positions are right;
- every substitution has its own line, not the start of the literal.

**Fragments:**
- a hole in a piece of a condition is recorded with a mark;
- a log line and URL parameters do NOT count as a fragment;
- without a strong SQL sign a fragment is not taken, with the sign it is.

**Declarations:**
- all four ways of setting visibility give the right result (nine methods — nine
  expectations);
- class methods declared in a block are marked as class methods;
- "returns a statement", "returns a fragment" and "there is a query in the body" are
  three different signs on three different methods;
- the parameters are recorded.

**The columnar-store wrappers:** the first argument counts as a table ONLY for wrappers
from an explicit list; a dynamic name yields an expression and a pattern, not a table.

**Rendering:** the old form with a trailing arrow is seen; both branches of a ternary
expression are seen; an interpolated name yields a pattern; a name entirely in a
variable yields a blind spot; comments and page text do not count as rendering; the
logical name of a template is assembled correctly.

**Candidates:** a name from the database met in text yields one row with the right
counter; a column from the ORM's arguments is bound to the model's table; a variable
that was assigned a query is recorded together with its value and with the appended
pieces.

**Finding calls** (on real files in a temporary directory):
- a declaration does not count as a call;
- the file, the line, the surrounding method and the arguments are named;
- a template: the line numbers match the file; a branch spread across different tags is
  parsed; a template comment is not read;
- a dynamic call with a literal name counts as a call and returns the remaining
  arguments; a name assembled at runtime is counted separately and is not called a call;
- a symbol is as much a lead as a call, and does NOT produce a second record next to the
  call;
- mentions outside calls are classified, and the declaration did not get among them.

**Stylesheets:** `&-big` inside `.btn` declares `btn-big`; a name from a comment does
not count as a class; `@apply` is a use; `@import 'base/reset'` finds `_reset.scss`; a
reference to a package differs from a broken one; a media condition does not count as a
selector, while its body is parsed.

**JavaScript:** the head of a declaration does not count as a call; `...fn()` does count
as a call; `_(` inside a regular expression and inside a template string does NOT count
as a call, while `${build(x)}` does; a build entry assembled by `path.join` is found; an
import binding is recorded together with the number of mentions.

**The verdict journal:** every class of the register has an expression of its subject,
and there is ONE of it — a spec checks that the filtering and the enumeration take it
from the same place (let two spellings drift apart and the verdict silently stops
recognising its finding); a "false" verdict removes a finding from the selection; editing
the anchor file brings it back.

**Encoding:** a value from the environment with non-Latin letters does not kill the
command; the output of an external command is scrubbed; the self-check with no locale
passes. The guard is proven by REMOVAL: take the scrubbing out and the example must
fail.

**The sweep gate:** a changed file is not skipped (the error here is in the dangerous
direction — answering from old content while looking fresh); a change of the parse inputs
(the schema, the habits) causes a re-parse with the files unchanged; a reverted edit is
noticed.

**The queries inside the reports themselves:** in the squished (`squish`) queries there
is not one `--`. This is not a matter of taste: a comment inside such a query sweeps
everything to the end of the line into `--`, and that is how a `group by` was silently
switched off for us and the command died in the middle of its work. The guard was proven
by removal.

A separate trap in the tests themselves: if a fixture is written as a literal with
interpolation, the substitution will happen IN THE TEST, the parser will receive a string
with no hole, and the example will pass for the wrong reason. Write fixtures as literals
without interpolation.

---

# Part IX. The order of work

The benefit arrives fastest in this order:

1. **The schemas of every environment separately** + a divergence report. Half a day,
   and it already finds what nobody knew about.
2. **Parsing SQL with a real parser** + "where this table/column is touched" with the
   fact/candidate split. The main layer.
3. **Facts from the running application.** Almost free, and it ties everything else
   together.
4. **Incrementality** by checksums, so that a query catches the index up by itself.
   After this people start using the tool.
5. **Tests for the parser** — before there are many rules.
6. Then as the need arises: the place of execution, substitutions, production logs,
   unused things, what an edit touches, architectural latches.

A cold start:

```sh
bin/rails xref:init     # create the index database and apply its schema
bin/rails xref:schema   # fetch the schemas of every source
bin/rails xref:app      # facts from the running application
bin/rails xref:places   # the set of services from the live containers
bin/rails xref:code     # parse the tree (the first pass takes a minute)
bin/rails xref:json     # the keys inside schemaless fields
bin/rails xref:views DATE=…   # a day of logs; accumulate by day
```

Then what a HUMAN starts rather than a catch-up: it reads production data.

```sh
bin/rails xref:sql DATE=…         # the patterns of executed queries from the logs
bin/rails xref:sql_profile DAYS=30 # the same from the database's statistics: a window of weeks
bin/rails xref:fill TABLE=…        # a full scan of one table's data
```

Dependencies: the code parse runs AFTER the schemas are fetched (without names from
the database there will be no candidates) and AFTER the application facts (without the
models, accesses through the ORM cannot be bound to tables).

**The layout of the files.** Every file is responsible for one layer and is made
separately from the rest; the collectors print nothing, the reports parse nothing.

| File | What it is responsible for |
| --- | --- |
| `config/xref.yml` | the single source of truth: the store, the sources, the tree's habits, the logs, the rules |
| `lib/xref.rb` | reading the config, the habits, bringing bytes to UTF-8 |
| `lib/xref/store.rb` | the index's schema, all the views and all the writing into it |
| `lib/xref/schema_source.rb` | fetching one source's schema, the transports |
| `lib/xref/code_scanner.rb` | parsing one file — the only place that knows about the record kinds |
| `lib/xref/scan_plan.rb` | the sweep gate: what to parse and whose SHA to compute |
| `lib/xref/call_sites.rb` | call sites and mentions on demand (a wrapper over the search) |
| `lib/xref/text_search.rb` | text search: one engine for every report |
| `lib/xref/erb.rb` | assembling Ruby out of a template — ONE for the whole index |
| `lib/xref/css.rb` | stylesheets: selectors, `@import`, `@apply` (IV.18) |
| `lib/xref/js.rb` | javascript: modules, Stimulus, functions, library bindings (IV.19) |
| `lib/xref/markdown.rb`, `nginx.rb`, `shell.rb`, `structured.rb` | the layers beyond the code: documents, the front end, the shell, settings |
| `lib/xref/locales.rb` | translation keys from the files, bypassing the library |
| `lib/xref/db_sql.rb` | the bodies of rules, triggers and functions — with the same SQL parser |
| `lib/xref/rails_facts.rb` | facts from the running application |
| `lib/xref/run_places.rb` | the set of services from the live containers |
| `lib/xref/env_keys.rb`, `migrations.rb` | environment key names and the applied migrations |
| `lib/xref/json_keys.rb` | the keys inside schemaless fields |
| `lib/xref/view_runtime.rb` | parsing production logs on the node (renders and actions) |
| `lib/xref/sql_runtime.rb` | the patterns of executed queries from the logs |
| `lib/xref/sql_profile.rb` | the same patterns from the database's own statistics (IV.15) |
| `lib/xref/data_facts.rb` | column fill rates and index scans from live data |
| `lib/xref/verdicts.rb` | the register of finding classes and the journal of checks (VI.3) |
| `lib/xref/rules.rb`, `components.rb` | architectural rules with a latch, and the component model |
| `lib/tasks/xref.rake` | the tasks and all the reports (41 tasks) |
| `bin/xref`, `bin/xref-run` | the wrapper and the fast entry point without the full framework |
| `spec/lib/xref/` | 304 examples: the parsers, the gate, the search, the encoding, the journal |

## What not to do

**Do not write a second schema parser.** Load the dump into a database and fetch it
with a query.

**Do not build a call graph with receiver resolution** on a large dynamic codebase. It
will give a confidence it does not deserve. An on-demand parse for named names is
honester and a hundred times cheaper. Search for whole words and a fixed string; if
there are hundreds of names, a search with the version control system's built-in means
does not fit into a reasonable time — one combined expression and one pass over the
files is orders of magnitude faster.

**Do not enable heavy diagnostics in production** for the sake of an analysis tool. If
the query statistics collector requires restarting the production database, that is
disproportionate; the logs give almost the same thing for free.

**Do not try to guess what can be asked.** The routes, the models, the schedule — from
the application. The set of services — from the live containers. The contents of
schemaless fields — from the data.

---

# Part X. What will remain unknown — and how to measure it

The section without which everything else is dangerous. A tool whose blank spots are
not counted is read as a map with no blank spots — and people walk it confidently.

**"A blind spot" means three different things, and they must not be kept in one
count.** While we kept them that way, the count was twice the real one:

1. **real blindness** — "there is a query (or a key, or a template) here, and we do not
   know which";
2. **resolved** — the name is assembled from a variable, but the variable is assigned
   nearby: there is an answer, and keeping that in the ignorance count is lying about
   yourself;
3. **a piece or text** — the string breaks off mid-word, or it is a phrase that began
   with a keyword. There is nothing there not to know.

Print the three numbers separately in the self-diagnosis. For us, after the separation
and six fixes to the parse, 317 real blind spots were left instead of 731; 52 went into
"resolved", 141 into "pieces". Now, after one more cause of silence was found (below,
about the line number in a heredoc): **280 real ones** — 255 queries and 25 accesses to
the columnar store — **86 "resolved by assignment"** and **142 "a piece or text"**. The
numbers have barely moved, not because the parse stopped improving but because in the
same time the parsed tree grew from 8 to 21.5 thousand files: blindness is counted over
everything the tool has begun to see.

**The classes of real blindness, in order of size.** The numbers are ours, and what
matters is not their size but that every class is named and counted:

| class | ours | what exactly we do not know |
| --- | --- | --- |
| **a style class name at runtime** | **2,421** | which rule will apply. Another 287 yield a pattern → candidates. The largest blind area of the whole tool |
| an assembled translation key | 420 accesses, 139 patterns | which text will be shown — but for 94 of the patterns the store gives an ANSWER: "one of ≤20 keys". What stays blind is 42 wide ones and 3 with a short prefix |
| a variable key on a result row | 175 | which column is taken. It was 1,956 until the RECEIVER was checked; for 44 records the table is now known |
| `select *` | 696 places, 150 tables | for 92 tables the star **hides nothing** (a measurement, not an assumption); for 58 it remains |
| a query with an unresolvable substitution | 255 (+25 for the columnar store) | this is already AFTER resolution by assignment (86 places). Holes in a table-name position: 154; a third of such places are in one-off migrations |
| a template name at runtime | 308, of them 181 blind | which partial will be rendered. 127 yield a PATTERN → candidates; of the blind ones 77 closed once a contour helper with a literal also became a pattern |
| an assembled Stimulus controller or target name | 52 | which controller this markup activates; the link is not traced |
| an assembled bundle name | 3 | which set of styles and scripts the page will get |
| a JavaScript call — BY NAME ONLY | 8,091 calls over 4,361 functions | who exactly is called: the receiver is not resolved. That is a decision (part IX, "do not build a call graph with receiver resolution"), but it has to be written into the limits |

**Matching BY LINE NUMBER is the worst way to link two records about one query.** The
record "the table name is assembled in full" is placed on the line where the query
starts, while the record about the substitution itself is on the line where that
substitution stands. In a query written as a heredoc (and that is the most common way to
write SQL) they never coincide, and resolution by assignment did not fire AT ALL: out of
166 such places, not one, even though `TABLE = '…'` stands in the same file, a line
above. The cure is not a wider tolerance but moving the knowledge: the root of the hole
is recorded by the query parse itself, which creates both records. For us that is 34
blind spots turned into facts, and nine table names the index did not know at all
(`identity_audit_events`, `events_log2`, `partner_stat_common`).

**A blind spot whose answer lies in your own data is not blind.** The largest of the
named ones (accesses to a translation by an assembled key) turned out to be half like
that: the pattern `user_notifs.L$1` is not "something unknown" but "one of
`user_notifs.Lmen`, `user_notifs.Lwomen`", and the text store knows it. Matching the
patterns against the store gave an answer for 94 patterns out of 139 — and one FINDING
that was statically invisible altogether: the pattern `month.m$1` matched no key at all,
because the namespace is called `months`, and the screen's heading printed "translation
missing".

Two traps in that matching, both my own and both found by measurement:

- **take the prefix and the tail AROUND the hole, not by gluing the piece before to the
  piece after.** The glue `pitest.scales.scale_$1.expl.$1` →
  `pitest.scales.scale.expl.` matches nothing, and that is how I measured 36 "patterns
  with no match" instead of one;
- **`like prefix || '%'` is unfit for keys**: key names are full of underscores, and in
  LIKE an underscore is a wildcard. A comparison of the prefix as text is needed
  (`starts_with`), otherwise `payments.subscr_%` matches `payments.subscrXxx`.

**Check the RECEIVER before calling an access by variable a blind spot.**
`something[variable]` in Ruby is a column read, an array access and a file glob all at
once. While we did not tell them apart, the count of our own ignorance was twelve times
too high: 1,956 instead of 156. That is the worst kind of error — it makes the tool look
more modest than it is and devalues the real findings. The sign of a receiver: a
variable that was assigned the result of a query, or a name that in this tree always
means a row (`row`, `line`, `info`). The count is a LOWER bound, and say so: a result row
named unusually will not get into it.

**And a loop over a list of columns is not a blind spot at all.**
`['a','b','c'].each { |key| row[key] }` reads exactly the columns in the list: bind the
block's parameter to the composition — the list is sometimes right there in the loop,
sometimes declared in the same file, sometimes known from an earlier parse. For us that
is 194 accesses that stopped being
blind. Require ALL the elements of the list to be known column names, otherwise any
loop over words lands among the reads.

**Coverage is a class of its own, and it is confused with blindness more often than
anything else.** "We did not measure" and "we do not know" are different answers, and
the first is cured by a run:

- **files outside the parse altogether**: for us that was 15 thousand out of 23,337,
  and the silence about them read as "there is nothing there". After seven parses
  (documents, settings, scripts, front-end configs, JavaScript, TypeScript,
  stylesheets) what is left outside the parse is **1,826 out of 23,411**: images, fonts
  and vendored dependencies. That is no longer silence but a named list;
- **and inside a parsed layer there remains content that is not read**: stylesheets from
  `node_modules` are not read (so "there is no rule in any of OUR stylesheets" means
  nothing for a library's class), we deliberately do not go inside JavaScript packages
  (IV.19), the bodies of functions in the database's procedural language are not parsed
  (IV.1). That is not blindness of the parse but a declared boundary — but in the report
  it has to stand next to the answer, otherwise it reads as a conclusion;
- files outside the reference graph: for us that is 1,037 application files. As a single
  number it reads as "a thousand dead files", and that is almost entirely untrue — which
  is why the classes are mandatory: **rendered in production while the graph does not see
  them** (53 — a shortfall of the GRAPH, not the death of a file), templates with no
  observation (666 with an eleven-day window), JavaScript (42 — build roots and
  standalone scripts, which nobody imports by construction), there is a reference and no
  path (170), **helpers** (64 — the framework includes them implicitly, and they are
  never called by name), with no constant in the inventory (7 — there is nothing to look
  up by), and only **35** are "not one reference by name", that is, candidates for
  removal.
  And the caveat in the caption must be computed FROM THE DATA: a baked-in "the
  observation window is one day" survived the window's growth to eleven days for us and
  was printed as an untruth next to a correct number — caught while proof-reading the
  report, not by a run;
  Two subtleties of the count, each of which produced false candidates: the
  application's inventory gives ONE name per file (and we have a 735 KB file with
  ninety-two modules — everything it declares has to be checked), and the record kind is
  called `const_ref`, not `const` — an error in the kind's name declared 272 files
  candidates instead of 35;
- **a chain that is not provable everywhere**: the question "is there a rule for this
  class in THIS contour" (IV.18) requires the layout to name a bundle. We have three
  such template trees; about the rest — **2,376 classes** — the layer keeps quiet, and
  says that it keeps quiet rather than answering "there is no rule";
- the live-data measurement: done for 28 tables (820 columns) out of eight hundred and
  something — three per cent; the rest are "not measured". And it is started by a human,
  so the coverage does not grow by itself;
- **the observation window** — print it next to every "not touched in production",
  otherwise the statement is unreadable: "not touched in one day" and "not touched in a
  hundred days" differ in everything and look the same. Days do NOT overwrite each
  other, and the window grows by itself with every collection; trim only the tail beyond
  N days, otherwise in a year the table holds a million and a half rows answering
  nobody's question.

  And an honest observation about the width of that window, because intuition deceives
  here. We expected the second day to show plenty of new things — it showed **zero**: not
  one new table, not one new column, and only 18 new query patterns out of 353. In terms
  of tables and columns the one-day window turned out to be saturated, and it is worth
  widening not for coverage but for the RARE: a weekly or monthly cron job does not fall
  into a day at all, and it is caught by weeks of observation rather than by a second
  day;
- the patterns from the logs are trimmed by length: for us 744 out of 8,475 did not
  parse;
- **the window DIFFERS between sources, and there is no shared number here.** The
  collection from the database's statistics (IV.15) is configured on one of our three
  sources: there the window is eight days, for the others two. Print it per source — "not
  touched in production" with different windows means different things;
- files with no component: 13,479 out of 21,585 (62 %) — the architectural rules do not
  see them. Almost all of that mass is machine-generated inventories in `doc/` (one
  folder holding six thousand files), and that is exactly why the number has to be
  printed with a breakdown by directory: as one number it reads as "the model describes a
  third of the tree", and by directory as "the model describes the code, not the
  inventories";
- environment keys read by something other than Ruby (nginx, shells, the container
  itself): 144. There is nothing in this tool to check them with.

**Structural limits — what cannot be learned this way at all.** They have to be listed
honestly, otherwise every next reader will start hoping again:

- `method_missing`, `send` with a name assembled at runtime, `define_method`,
  `respond_to?`;
- accesses through ORM associations: `user.photos.each` names no table;
- the value of a runtime variable — which shard was chosen. The logs close that
  partially and only for what ran on the days collected;
- a method that returns a query from a branch of a condition does not count as
  "returning a query": the last expression of the body is what is looked at;
- a query fragment is only taken with a strong SQL sign — a value substituted into
  `"a=#{b}"` will not enter the index, and that is the price of having no noise from log
  lines.

**How to measure all of this in one run.** The self-diagnosis has to print: the three
blindness numbers, the classes by record kind, the coverage (files in the graph, tables
with a measurement, the observation window) and, separately, the counters that reveal a
breakage of the parse itself (for us that is "accesses by key from templates": a zero
there means the template parse is broken, not that there are no accesses).

---

# An honest summary

The value of an index like this is not that it finds more than a human. Checked on a
real task: of the twenty-nine files affected, twenty-eight were found by hand too, in
three rounds of reading. The value is that **it finds them in a second instead of three
rounds** — and that it did find the twenty-ninth.

And in that it names its own boundaries. A map that keeps quiet about its blank spots
is more dangerous than no map at all: people walk it confidently.

<!-- translated-from: doc/guide.ru.md sha256:fa510cd5a10c6f19730883d585eb6d0c9a2b56e4ac112354e13343f28af7319e -->
