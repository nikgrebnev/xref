# xref

**An index of your code and your live databases — fast enough to use instead of grep.**

[English](README.md) · [Русский](README.ru.md)

`grep` answers "where does this string appear". That is rarely the question. The
question is "where is this column actually touched, by which query, reachable
from which route, and is that column present in every environment we deploy to".
Answering that with `grep` and `find` means a dozen searches followed by an hour
of reading the hits. `xref` answers it in about a second, and tells you what it
does not know.

```sh
bin/xref where users.email      # every place a table or column is touched:
                                #   parsed SQL, ORM, interpolation, text — kept apart
bin/xref blind                  # code queries a table that this environment lacks
bin/xref drift                  # how the schemas of your environments differ
bin/xref find "payment failed"  # text search, plus what the index knows about each hit
```

No daemon, no service, no cloud. One local database, one shell wrapper, about
15,000 lines of Ruby. The only hard dependency is a SQL parser for your
database.

This repository ships **both the working tool and the specification to rebuild it
from scratch** — see below.

---

## Two things in one repository

**1. The tool, ready to run.** Drop it into a Ruby/Rails + PostgreSQL project and
it works the same day: `bin/xref refresh`, then ask it questions. Parsing is
organised per language, and a tree's own habits live in configuration rather than
in the parser — so teaching it your stack means adding a parser for your language
or a rule to the config, not rewriting the engine. The storage contract, the
reports and the views do not change.

**2. The specification, enough to regenerate it from scratch.** The guide is
written to be *executed*, not admired: the complete storage schema (31 tables, 64
views, applied to an empty database with zero errors), the record contracts,
working code for exactly those parses where a mistake is easiest and least
visible, the verification experiments with their results, and an honest list of
what was never checked. If your stack is Python/MySQL, Go/ClickHouse or anything
else, you are not porting code — you hand the specification to a capable coding
agent and get an equivalent tool, with the two dozen mistakes already paid for by
someone else. That is the deliverable that survives a change of language: the
engine is fifteen thousand lines, but the hard part was never the lines.

---

## Install it in five minutes

Two shapes, and the choice is only about where the files sit.

**Standalone**, next to the project it indexes — nothing is added to your
application, not even a gem:

```sh
git clone https://github.com/nikgrebnev/xref && cd xref
bundle config set --local path vendor/bundle && bundle install
createdb xref                      # the index lives in its own database

# point it at your tree: config/xref.yml, one line
#   project_root: ../my-application

bin/xref code                      # parse the tree
bin/xref audit                     # and read what it says about its own gaps
```

**Inside a Ruby application** — one command from this repository:

```sh
script/install.sh /path/to/your-application
```

It copies the engine, the rake file, the wrapper and the specs, rewrites the one
`require` line in the specs so they run inside your suite, and **never touches
`config/xref.yml`** — that file is yours. Add `pg_query` to your development
group, then `bin/xref code`.

The install also puts a **skill** into your tree (`.claude/skills/xref/SKILL.md`),
because the tool is only worth anything if it gets ASKED instead of a text search —
and a fresh agent session has no way of knowing it exists. The skill is what the
agent matches against; `XREF_SKILL=global` puts it in `~/.claude/skills` instead,
`XREF_SKILL=none` skips it.

Your tree will differ from the one this engine grew in, and that difference
belongs in `config/xref.yml`, not in patched code: the `idioms` section describes
the habits of a tree — which methods fetch a result row, what such a variable is
called, which wrappers take a table as their first argument, which languages a
translation key must exist in, which columns a recent cohort is counted by. A
project adds reports of its own in a separate rake file inside `namespace :xref`:
`bin/xref <name>` passes an unknown command on as `xref:<name>`.

If something about your tree cannot be said in the configuration, that is a
defect of this repository rather than of your tree — say so in an issue. The
reason this matters is measured: the project that vendored this engine by hand
lost its local adaptations twice to an update, silently.

Either way the next step is the same: describe your environments in
`config/xref.yml` (`config/xref.example.yml` documents every section with the
reason it exists), then `bin/xref schema` and `bin/xref refresh`. Until a schema
source is configured the index still answers about the code — and says that the
schema side is unmeasured rather than empty.

**Read `bin/xref audit` before you trust any answer.** It prints what the index
does not know: how many queries it could not parse, how many names are assembled
at runtime, how many files no reference reaches, how wide the observation window
is. An index whose blind spots you have not read is a map without its white
patches.

---

## Quick start: what to tell your agent

Paste this to the coding agent working in your project:

```text
Install xref (github.com/nikgrebnev/xref) into this project and make it my
primary code search.

1. Read its README first. Vendor the engine: lib/xref/, bin/xref, the rake tasks.
2. Create a local PostgreSQL database for the index and apply the storage schema.
3. Register a source for every environment we deploy to, plus our structure.sql
   dump. Run `bin/xref refresh`, then `bin/xref audit` and tell me what it
   reports about its own gaps before you tell me it works.
4. Put this tree's habits in xref's configuration, never in the parsers: which
   directories to skip, how our table names are sharded, where templates live.
5. Verify, do not assume: take a column you already know well, run
   `bin/xref where <table.column>`, and compare against what you can find by
   hand. Report what it missed and why.
6. Then add a standing rule to our agent instructions (CLAUDE.md / AGENTS.md):
   for any question about where something is used, call `bin/xref` before grep;
   for text search use `bin/xref find`, which also reports whether the file is
   reachable from production and which tables it touches.
```

Three things worth knowing while it does that:

- **Not on Ruby/Rails + PostgreSQL?** Give the agent the specification instead of
  the engine and ask it to build the equivalent for your stack. That is what the
  specification is for, and it is the longer but better-documented path.
- **The standing rule in step 6 is the point.** Without it the agent uses xref
  once, in the session where it installed it, and reaches for grep in the next
  one.
- **Don't accept "installed and working" without step 5.** An index that answers
  from a stale parse looks identical to a fresh one — that failure mode is why
  the tool gates its own catch-up on parse inputs, and it is the first thing to
  check in a new installation.

---

## Why not grep

Three reasons, each of which cost a production incident in the project this tool
was built for.

**A name is a poor key.** A short column name is simultaneously the name of a
server in the infrastructure and the most popular local variable name in the
tree. The search returns three hundred matches, six of which concern the
database.

**The query lives in a string, not in code.** Where SQL is written as text, the
IDE does not know that the string touches a table — to it, that is just text.
And then there is an interpolation inside that string, and the table name is
assembled at runtime. "Find usages" finds nothing at all.

**Environments have drifted, and the code does not show it.** Once you have more
than one live database, sooner or later a table exists in only some of them. The
code looks impeccable and fails only where the table is missing. That is the
worst class of bug: it stays silent until production.

`xref` is not "grep, but faster". It is **grep plus meaning**: for every hit it
also tells you whether the file is reachable from production, how deep, who
calls it, which tables it touches, how many blind spots it contains, and whether
it was actually rendered in live logs.

---

## Recommended as your primary search

This tool is meant to be the **first** thing you reach for, not a specialist
instrument you remember once a month. That design goal has a measurable
consequence, and it is the single most important lesson in the project:

> A tool that answers in six seconds is only ever asked questions that are
> obviously structural. For everything else, a human — and an agent — reaches
> for grep, and ends up using habit rather than a tool.

When that was first measured, `where` took **6.5 s** while `git grep` over the
same tree took **0.24 s**. The index query itself took **0.04 s** — the index was
two hundred times faster than grep, and the wrapper around it seven hundred times
slower. All of it was framework loading, re-hashing every file on every command,
and two badly shaped SQL joins. After the fix: 6.5 s → 1.3 s per query, 26 s →
2.5 s for a graph traversal, 318 s → 7.7 s for the full text report.

**Latency is a property of the tool, not of its plumbing.** If it is slow, it
will not be used, and an unused index rots.

### For AI coding agents

`xref` was built in and for agent sessions, and it is a better fit for an agent
than for a human: one command replaces a dozen `grep` round-trips, the answer is
a compact table rather than hundreds of raw lines, and — crucially — the answer
states its own uncertainty. An agent that greps a tree sees matches; an agent
that asks the index sees facts, with "I don't know" where that is the truth.
Point your agent's instructions at `bin/xref` and tell it to prefer it over
`grep`/`find`.

---

## What it answers

41 commands. The ones used daily:

| Command | Answers |
| --- | --- |
| `where <table[.column]>` | every place it is touched — parsed SQL, ORM, "looks like it by text" — listed separately |
| `find "<pattern>"` | text search, enriched: is the file reachable from production, what tables it touches, who calls it |
| `column <part-of-name>` | which tables and which environments a column lives in |
| `blind` | code queries a table that is absent from that environment |
| `drift` | how the schemas of the environments differ from one another |
| `migrations` | what is applied in each environment, what is missing, where they diverged |
| `env` | environment keys the code reads that the environment does not define (**names only — values are never read**) |
| `texts` | i18n: a key is called but has no translation, and the reverse |
| `holes [name]` | what gets interpolated into a query, into which position, and where the text comes from |
| `calls [method]` | who calls it: from code, from a template, via `send`, by symbol, by route |
| `callers <file>` | who reaches this file, and who rendered it in production |
| `dead` | unused routes, actions, controllers, methods |
| `changed [ref]` | what an edit touches: methods, their callers, tables, and environments missing those tables |
| `scope "<task>"` | from a task to files: entry points, a map, a reading order, tables at risk, blind spots |
| `boundary <file>` | what to read before editing this file |
| `columns <table>` | per column: what is read, what is written, what is dead — and what the live data says |
| `lineage <table.column>` | where a column's value comes from |
| `views` / `sql` | which templates and which queries actually ran, from production logs |
| `sql profile` | the same from the database's own statistics: a window of weeks instead of days |
| `css` | styles: what is declared, what includes it, which classes nothing mentions — and whether a rule reaches *this* contour |
| `js` | JavaScript: the template→controller→method chain, top-level functions, calls into libraries |
| `docs` | documentation as a layer: broken links, stale paths, examples that do not parse |
| `front` | front-end configuration defects and dangerous places in scripts |
| `rules` | architectural rules with latches, and contracts declared in prose |
| `findings [class]` | open findings by class, how many verified, and the **false-positive rate of that class** |
| `verdict <class> <subject> …` | record that a finding was checked against the first source — a false one leaves the reports until the file changes |
| `locale` | a self-check of the encodings: what Ruby sees with no locale |
| `audit` | an audit of the index itself: connectivity, noise, gaps |
| `refresh` | refresh schemas, application facts, code |

Queries catch the index up on changed files by themselves, so an answer reflects
the tree as it is now, not as it was yesterday.

---

## Supported languages and sources

Parsing is per language, not per regex. What is understood today:

| Layer | Extensions | What is extracted |
| --- | --- | --- |
| Ruby | `.rb` `.rake` `.ru` | a real syntax tree (Prism): declarations, visibility, calls, `send`, symbols, column access by key, SQL in strings and heredocs |
| Templates | `.erb` `.haml` `.slim` `.builder` `.jbuilder` | **templates are code too**: Ruby inside tags goes through the same walk as `.rb`, plus render calls and partial names (including assembled ones) |
| JavaScript / TypeScript | `.js` `.jsx` `.mjs` `.ts` `.tsx` `.mts` | modules, classes, Stimulus controllers and their actions, template→controller→method wiring, unreachable code |
| SQL | `.sql` | a real parse via the database's own parser: tables, columns, the position of each interpolation |
| Stylesheets | `.css` `.scss` `.sass` `.less` | declared classes (including `&-suffix` composition), `@import`/`@use` with path resolution, `@apply`; from the other side, the classes the markup and the code mention. The parse is deliberately partial: the cascade is a browser's job |
| Markdown | `.md` `.markdown` | headings, links, path mentions, and **code blocks parsed by the same parsers as files** — a query in a document that does not parse is an example nobody ever ran |
| YAML | `.yml` `.yaml` | two-layer: first the Ruby inside ERB tags, then the key tree with ERB cut out by marker. This is where `database.yml` reads the environment — invisible until YAML is parsed |
| Shell | `.sh` `.bash` | environment keys, heredocs with SQL parsed by the SQL parser, dangerous commands; script-local variables are told apart from real environment keys |
| nginx / Angie | `.conf` | locations, `rewrite`/`try_files` defects, declared service composition |
| JSON | `.json` | key trees, with a depth limit |

Non-code sources the index also reads:

- **live environment schemas** — over ActiveRecord, over `ssh psql`, from a
  repository `structure.sql` dump, or over Thrift for HBase-style stores;
- **production logs** — which actions ran and which templates were actually
  rendered (counted separately: an action that answered with JSON renders
  nothing, and by a template count alone would look dead);
- **the running application** — routes, models, autoloading;
- **the live data itself** — column fill rates, defaults, recent cohorts, index
  scans.

The stack in the reference implementation is Ruby/Rails + PostgreSQL. The methods
do not depend on the platform; on another database only array types and `jsonb`
change. A younger project that is entirely on an ORM needs only the first three
layers.

---

## How it works

**One storage contract, fixed before any code.** 31 tables, 120 views (65 of
them written out in the specification). Sources of
schema (environments, the repository dump, a columnar store) are separate rows,
so "this table exists" is always "exists *where*".

**Four levels of proof, never mixed in one answer.** A column named in the code
is one thing; a column in a parsed query is another; a column in a query that
actually ran in production is a third; and the live data in that column is a
fourth. The reports keep them apart, because "nobody reads this" from level one
is a guess and from level three is a measurement.

**Incremental by content, with a cheap gate.** Re-hashing all files on every
command cost 1.5 s of the 6.5 s, almost always for nothing. A modification-time
gate costs 0.018 s — eighty times less. Modification time is never treated as
proof in either direction: if it matches, the previous checksum is trusted; if it
differs, the checksum is recomputed and compared. A file rewritten with identical
content is not re-parsed. The gate also covers the **inputs** of the parse
(schema names, the model map, the parser's own checksum), because a schema change
with no file edit must still invalidate the parse — the index once insisted for a
month that two tables were absent from two environments.

**Text search is a wrapper, never a second index.** The temptation is a string
table and trigram search. Don't: a second index would age separately from the
first and need its own freshness checks — exactly the disease the tool cures. A
wrapper over `rg`/`git grep` is fresh by construction, and the index adds the
meaning the search cannot know. Search is a **prefilter**; the precise rule is
applied to the hits by the tool's own parse, so the rule never has to be restated
in someone else's regex dialect.

**Findings are verified against the first source before a human sees them.** In a
new layer, false positives outnumber real ones by two or three to one — measured
across seven classes: 137 broken examples → 7, 632 broken links → 15, 25
`rewrite` defects → 2, 22 missing translations → 6, 13 references to a
non-existent column → 4, 3 dead controllers → 1. None of the filters that
produced those reductions could have been invented in advance; they are visible
only on the findings themselves. So the verdict is stored next to the finding,
and every class prints its own false-positive rate — otherwise all findings read
as equally weighty, and they are not.

---

## It names its blind spots

The first rule of the project:

> **A tool that does not name its blind spots lies silently.** An absent record
> reads as "there are no links". Silence is not an answer; "I don't know" is an
> answer.

So "blind spot" is split into three counts that must never be summed:

1. **genuine blindness** — "there is a query (or a key, or a template) here, and
   we do not know which";
2. **resolved** — the name is assembled from a variable, but the variable is
   assigned nearby: there *is* an answer, and keeping it in a count of ignorance
   is lying about yourself;
3. **a fragment or prose** — the string breaks off mid-word, or it is a sentence
   that happens to start with a keyword. Nothing is unknown there.

Keeping them in one number made the count twice as large as the truth. Checking
the **receiver** before calling a variable access blind brought one count down
from 1,956 to 156 — `something[variable]` in Ruby is a column read, an array
index, *and* a file glob. That is the worst kind of error: it makes the tool look
more ignorant than it is, and devalues the real findings.

Every report prints a status header: how many files are indexed, how old the
schema snapshots are, how many blind spots there are — and an empty answer is
explained rather than shown bare, because "this does not exist" and "the SQL
parser was unavailable, so the parse is incomplete" are different statements.

---

## Measured, not estimated

On the tree it was built for — 600,000 lines, twenty years of history, SQL in
strings, five live databases with drifted schemas:

- **21,592 files parsed** of 23,411 tracked (images, fonts and vendored
  dependencies are out of scope — and that list is printed, not implied);
- **full parse: about three minutes**; catch-up after a one-file edit: **about a
  second**; a query with no edits: **1.3 s**;
- 308 spec examples, 2.5 s — here and in the tree the engine comes from, the
  same examples;
- the storage schema and all 65 views of the specification apply to an empty
  database with zero errors, and every view answers a `select`;
- the first standalone run of this repository found **six portability defects**,
  every one of which was a defect in the original tree as well. They are listed
  in [CHANGELOG.md](CHANGELOG.md).

---

## Status

**Published and running.** The engine (`lib/xref/`, `bin/xref`, the rake tasks),
the 308 specs, the example configuration and the specification are all here. The
same engine runs inside the 600,000-line application it was grown in, and the
files are byte-identical between the two copies — that is deliberate, and
[doc/workflow.md](doc/workflow.md) explains how a change travels between them.

What is honest to say about its age: the engine is young outside its own tree.
It has been exercised against five live databases, production logs and real data
for weeks — but as a standalone installation it is days old, and the first
standalone run found six defects in an afternoon (CHANGELOG). Expect to find
more, and expect the tool to tell you where it is blind rather than to pretend.

**The specification is in English** — [doc/guide.md](doc/guide.md), with
[doc/verification.md](doc/verification.md) next to it. The Russian originals stay
as `*.ru.md` copies: they are generated mechanically from the tree the engine
comes from, so they are the ones that cannot go stale, and each English document
carries the checksum of the Russian copy it was translated from (the publish step
says out loud when a translation has fallen behind). A few words are left
untranslated on purpose — the values the running tool prints into its reports —
and every one of them is glossed where it appears.

Requirements for the ready-to-run tool: Ruby 3.x, PostgreSQL for the index
itself, `pg_query` for SQL parsing, `prism` for Ruby parsing, and `rg` or
`git grep` for the text layer. Regenerating from the specification requires none
of these — only a database that speaks SQL and a parser for your language.

**The SQL parser is loaded on demand and its absence is survivable** — it is a
developer's dependency, and a `require` for it in a file the application loads at
boot would mean a production image without that gem refuses to start. Without the
parser the index is simply poorer, and says so.

---

## Authorship

Idea, design brief and direction: **Nik Grebnev** — he posed the problem, set the
goals, supplied the production tree everything here was measured against, and
rejected the answers that were wrong.

Implementation: **written entirely by Claude**, Anthropic's Opus model, in Claude
Code sessions — every line of the engine, the specs and the specification.

That is also why the lessons in this README are phrased the way they are. Every
rule in it corresponds to a specific failure in a real session: an index that
claimed two tables were missing for a month, a monitor that reported "no errors"
after reading a log up to the first invalid byte, a report that printed six
hundred findings when fifteen were real. The tool is, in large part, a record of
those mistakes made permanent so they cannot recur.

---

## What is in this repository

| path | what it is |
| --- | --- |
| `lib/xref/`, `lib/tasks/xref.rake`, `bin/xref*` | the engine, the tasks and the wrapper — byte-identical to the copy running inside the application it grew in |
| `spec/lib/xref/` | 308 examples. Every one of them closes a mistake that was once made; the comment above it says which |
| `script/install.sh` | installs the engine into a tree and never touches that tree's `config/xref.yml` |
| `skills/xref/SKILL.md` | the agent skill: when to ask the index instead of a text search, how to read a fact against a candidate, and the three rules that make an answer worth quoting |
| `config/xref.example.yml` | every section documented with the reason it exists |
| `doc/guide.md` | the specification: the storage schema, the record contracts, working code for the parses where a mistake is least visible, and part X — what stays unknown, with numbers. `doc/guide.ru.md` is the Russian copy |
| `doc/verification.md` | what was checked by execution, with the results, and an honest list of what was never checked. `doc/verification.ru.md` is the Russian copy |
| `doc/workflow.md` | how a change travels between the copies, and how to send one back |
| `CHANGELOG.md` | what the first standalone run found, and why that is the most interesting entry |

## License

MIT — see [LICENSE](LICENSE). The specification document, when published, will be
under CC BY 4.0, with the code inside it under MIT — so you may reproduce the tool
on any stack, commercially included, as long as the specification keeps its
attribution.
