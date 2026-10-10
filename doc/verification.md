# xref: what in the specification was verified, and how to run it yourself

A short note next to `guide.md` — the answer to a fair objection: "this is not an
installable package, and your implementation was never checked." Below is
exactly what was verified by execution, and the command that repeats it.
Consider everything else in the specification unverified.

## Verified by execution

**The storage schema and the views apply to a clean database.** 31 tables, 64
views, every one of them answers a `select` (recounted 2026-10-10, when the views
of the stylesheet and JavaScript layers went into the specification). The run:
take out of the specification the `sql` blocks whose first line after the leading
comments begins with the word `create` (the rest are collection queries, not the
schema), feed them to an empty database with `ON_ERROR_STOP=1`, and ask every
view for `count(*)`. Zero errors, and the view dependencies are closed — nothing
refers to anything the specification does not contain.

A subtlety of the run itself, which cost one false "does not apply": the filter
"the block begins with the word `create`" skips the main schema block, because
that one begins with a comment. Leading comments have to be stripped before the
test — otherwise the first thing to reach the empty database is a view, and there
are no tables yet.

**The code fragments parse.** All nineteen `ruby` blocks pass the syntax check
(`ruby -c`). That does not prove they work out of context — it proves they are
not fragments torn off something.

**The log-parsing program works, and shows why it needs two counters.** I fed it
four sample lines: two requests, one with two renders, the other with none at all
(it answered with JSON). Out came two action counters and two renders, each bound
to its own action. An action with no renders would look dead by the template
counter — that is the reason `Processing by` is counted separately from
`Rendered`.

**The tool works on a tree of 21,585 files** (out of 23,411 tracked; images,
fonts and vendored dependencies stay outside the parse — stylesheets have been
parsed since 2026-10-10). A full parse takes three minutes, the catch-up after an
edit to one file a little over a second, a query with no edits 1.3 s. 318 spec
examples, 2.5 s.

## The control checks from the register: run, with results

The numbering is yours. I ran them against an isolated index database, so as not
to mix anything into the working data.

**B10, "is a schema change visible when the source file has not changed" — did
NOT pass at first.** Incrementality rested on the checksum of the file alone. I
added a column to the schema and touched no code file — the index noticed
nothing. This is not theory: because of exactly this, our tool spent a month
claiming two tables were absent from two environments, where two hundred thousand
rows were sitting.

Closed by a digest of the parse INPUTS (names from the schema snapshots, the
model map, the constant map, plus the checksum of the parser itself) next to the
checksum of the file. The repeat run: the index said "the parse inputs changed"
and went through 8,278 files. I verified the effect rather than the fact of the
sweep: the name of the new column produced four records that would never have
appeared before the edit. The reverse case was run too — with nothing changed
there is no extra sweep.

**B17, "a disabled parser yields incompleteness, not success" — did NOT pass at
first.** Four sections with zeroes looked identical both under a full parse and
with the SQL parser absent.

Closed by two lines in the output: a state header on every answer (how many
files, how old the schema snapshots are, how many blind spots) and an explanation
of an empty answer — "under a full parse this is an absence" against "the parse
is INCOMPLETE: the parser was unavailable — this may be ignorance". Run in both
states on a separate database.

**B04, "is a new forbidden call detected" — passes.** I lowered a rule's latch by
one in memory (without touching the configuration file) — the report shouted
"GREW". The check is lifted into a spec: the guard fails together with the rest of
the tests once the tree has a new violation beyond the recorded count. On its very
first run it caught two genuine increases made that day by parallel edits.

**B02, "does it tell a column from a variable of the same name" — passes.** Parsed
SQL yields the column as a fact with an owner; a local variable of the same name
yields only a candidate by text and not one record about a column. Two examples in
the specs. On a live case: a name that exists as a column in eleven tables, as a
local variable and as a read from another table was separated into three distinct
entities.

**B18, "are a role conflict and hidden boundaries visible" — passes.** A component
model with roles and an order of layers, and the review of the model COMES BEFORE
the prohibition. That turned out not to be a formality: the review caught three
mistakes of my own before anything was forbidden on the strength of the model —
overlapping patterns (42 files in two components), a reversed order of layers
(declared 3,216 ordinary renders a violation) and noise in cycle detection. The
real finding after the repair: a pair of components with 974 edges one way and 415
back — one of the two holds two responsibilities, and no order of layers will
separate such a pair.

**B03, B08, B09, B16 — pass**, verified on the working tree rather than on a
sample: the consequences of an edit (diff → methods → callers → tables →
environments), the divergence of schemas between environments, separating a live
path from an unknown one (a pattern against a blind spot, plus counters from
production logs), and telling callers from callees apart.

**B01, "too large a reading area" — passes.** It used to pass partially: the short
"what to read for this edit" list answered about a FILE, that is, it required
already knowing where to look. A report FROM THE TASK was added: it takes a route,
an action, a table, a file or a word and prints, in reading order, the entry points
(routes with their request counts from observation), step 1 and step 2 along the
reference graph laid out by component (code before templates, templates folded up),
then the tables of the area that are missing somewhere, and the count of blind
spots and holes.

The control check — "does the map find a distant dependency known in advance" — was
made measurable and is printed with every answer: how many files arrived along the
reference graph only, and contain not one word of the task in their path — by file
name they cannot be found. The starting files are excluded from that count: a search
finds those too. On our test task — 243 files in the area, 156 of them of that kind.
That distant dependency known in advance is among them and lands in step 1: the data
of that task lives in the second storage, and the file that writes it there does not
share a single letter with the name of the task.

The shrinking of the area by the same run: step 1 is 89 files, and what has to be
read is 1 controller, 19 files of the service layer and 8 models; 60 templates are
compressed into four lines.

The remaining problems of the register — behaviour, requirements, releases, the team
— have nothing to do with a code index, and we did not drag them into it.

**The SQL inside the database is parsed by the same parser.** Rewrite rules,
trigger functions and our own functions: 59 rules per source, 761 records about
reads, writes and provenance. The control check: **165 columns are read by a rule
only** — without parsing the bodies all of them would have counted as "written,
but nobody reads it", that is, the error ran in the direction of "can be
deleted". Bodies in a procedural language are marked with the class "not parsed"
rather than with silence.

## What the tool itself was checked with — and what that check found

The most useful thing that happened to the tool in a day was being checked with
questions instead of trusted. Two questions ("which fields in this table are
superfluous") it could not close, and that cost three holes and five findings.

**Hole 1: there was no answer from live data at all.** "The code does not read
it" and "there is nothing in the column" are different statements, and the
decision "delete" requires both. A third collection was built: a full scan,
fill rate, deviation from the default, a recent cohort. The control check — the
collector reproduced, to the unit, the numbers obtained by hand. Three traps,
each of which spoiled the manual count once, are closed in the code and described
in the specification: the default (an untouched column with `default 1` looks
filled for everybody), the type (`boolean <> 0` kills the whole run, and the
table is left without a measurement rather than with zeroes), and recency
(141,006 fills in total and one in the past year).

**Hole 2: there was no check for "the code reads a column that does not exist".**
There was one for tables, none for columns. The first run found **five production
queries that cannot execute**; three of them miss by one word, which is why the
report now prints the nearest name. Verified against the first source: those
columns do not exist in the production database.

**Hole 3: nobody checked the composition of the field lists.** A repeated name
and a gap in a numeric series are two mechanical checks. They find the defect a
human found by eye in August: one name stands in the list twice, its neighbour in
the series does not stand there at all, and the column is filled for 19,452
people and read by nobody.

Along the way **three losses of precision in the parser itself** were found — each
of them invented a column that does not exist: a qualified star (`select u.*` gave
"the column `u`"), a subquery in `from` (the subquery's output was attributed to
the inner table), and the alias of a computation in `order by`. After the fixes
there were 13 false lines instead of 21, with the same five real findings. The
limit on the third fix was found by a spec: in `update t set c = c + 1` the target
is also "a name with an expression", and without that caveat the read of `c` on
the right lost its owner.

## A second attempt at the same question: four misses

The owner looked at the "not used" list and said: "the others should be in use
too." Checking every column he named found four misses, and all four in the same
direction — "not used" where it is in fact read:

1. **templates were not parsed by the tree sweep at all.** The tree sweep went
   over code files only, and taking a value by key is a kind of record from that
   parse. From code came 9,249 accesses, from templates ZERO — so the answer was
   about half the tree. Assembling Ruby out of a template is now one piece of code
   for the whole index (two copies drift apart silently); from templates came
   7,180 accesses;
2. **`create table … as select` and `drop table` did not count as the beginning of
   a query** — a thirty-column query began with `drop table if exists` and was not
   parsed at all;
3. **a string expression with no interpolation** (`"a-b<'32 days'::interval"`) did
   not count as a query or as a fragment. Now the parser decides, with the
   mandatory condition "the expression contains an operation": without it a field
   list `'a,b,c'` parses as `select a,b,c` and declares every column of the list
   used — exactly the mistake being walked away from;
4. **the same column on a copy of the table.** Two copies of the same data live
   side by side, and the column is read on the copy. Formally that is a different
   table; the report now says "the same column is read on …".

Plus a rule: **proof from the tests is not use in the product**; it is counted
separately and said in words.

The answer after the fixes was verified a SECOND, independent way — by grepping the
tree outside the field lists: for all 26 columns the tool called unused there are
zero outside occurrences (the only matches are comments, a local variable of the
same name, and a method with that prefix). In the second table not one unused
column remained: those not read by name are read on the copy.

## Blind spots: 731 → 317, and that too is a check by question

The blind-spot count reached 731, and the owner's question was not "explain it" but
"could they be made visible?". He turned out to be right: those places were blind
not because the code is incomprehensible but because the parse gave up too early.
Six rules — a parse in three passes (parameter → name → substitution in place of
the hole), an `and` joint for a hole after a complete condition, a literal `#{…}`
as a hole, telling a phrase from a query, looking up a table name by assignment,
separating "a piece" and "text" from ignorance — gave:

- **317 blind spots instead of 731**, plus 52 "found by assignment" and 140 "a
  piece or text", which no longer sit in the ignorance count;
- proportionally more facts: 5,107 records about columns against 4,676, and 2,107
  about tables against 2,033.

Why this matters more than it looks: a blind spot is not "one line is unclear" but
the whole query. One substitution in `from` carried away into ignorance the tables,
the columns and the write targets of that same query.

What stayed honestly blind: 159 — the table name is assembled in full and there is
no assignment nearby; 142 — a substitution where no replacement fits; 19 — text that
is not SQL at all. The self-diagnosis prints the three categories separately, so
that the total does not hide the fact that half of it is cured by parsing.

## The fourth level of proof: queries that actually ran

The largest blind area — a table name assembled by interpolation — is closed not by
parsing but by observation: the application log writes the name already resolved.
Collected over a day from four nodes: **2,605 patterns, 4.56 million executions, 202
tables, 555 columns**; 12 patterns of assembled names were resolved (`shard#{i}` →
eight real tables over 440 thousand executions).

Two rules, both verified by execution: values never leave the node (normalisation
stands first in the script, and there are no literals in the index), and digits
inside names are not touched — otherwise the very names the whole thing is done for
are destroyed. The spec for the normalisation script checks exactly that: a sample
of log lines, and on the output the names with digits are intact and the values are
gone.

**An independent check of the earlier answer.** The static answer "26 columns are
not used" was verified a second way, one that knows nothing about the code: of the
twenty-six, five appeared in the production logs, and all five only in the output
list — none in a condition, none in a write. For that it was necessary to
distinguish "the column is named in the selection" from "rows are filtered by the
column": in production the query selects the whole field list, and the first means
nothing.

## Three sources from the "later" list — built and run

**Executed SQL from the logs.** 4,563 patterns in a day, 4.5 million executions;
12 patterns of assembled names resolved (`shard#{i}` → eight real tables). Two
rules verified by execution: values never leave the node (normalisation stands
first in the script; the spec for the script checks exactly that — on the output
the names with digits are intact and the values are gone) and digits inside names
are not touched. Along the way it became necessary to distinguish "the column is
named in the selection" from "rows are filtered by the column" — and with that the
earlier answer about unused columns was verified independently of the code.

**Migrations across environments.** 172 in the tree, 187 applied in each
production environment; one migration is applied nowhere, and the local database
is six behind. The production environments agree with each other — so the
divergence of schemas does not come from migrations.

**Environment keys — names only.** 132/117/116 are set; the code reads 363 on
production paths. 125 keys are read by production code and exist in none of the
environments, with no fallback value at the read. The classes ("has a fallback",
"read as a flag", "an argument of a rake task") were verified by the fact that
without them the report began with `APPLY` and `LIMIT`.

**Texts — read outside the library.** 8,959 keys in 18 languages; 22 keys are
called and are not in the store, and for each one the report says what it actually
is. There are no missing translations among the keys that are called — all of them
have both main languages.

## Blind spots: three classes instead of one count

731 → 317 real ones. The separation alone gave half of it: "resolved by assignment"
(52) and "a piece or text" (141) have no business sitting in the ignorance count.
The rest is six parse rules, each closing a class (the parse in three passes, the
joint for a hole after a condition, a literal `#{…}` in single quotes, telling a
phrase from a query, looking up a name by assignment, the position of a hole inside
a condition).

What is left is named in numbers in the specification, part X: the largest is 416
assembled translation keys, then 317 queries with an unresolvable substitution, 308
template names built on the fly, 175 records of access by a variable key (it was
1,956 until the receiver was checked). `select *` left that list: 384 places over
150 tables are now measured, and for 92 tables the star hides nothing. Separately —
coverage: 1,206 application files outside the reference graph (35 of them candidates
for removal), a data measurement for two tables out of 1,241, and an observation
window for queries of two days which grows with collection.

## Measured, 2026-10-08

**The latency was measured by its terms rather than estimated.** `where` on a table
— 6.5 s, `git grep` over the same tree — 0.24 s, the query to the index database
itself — 0.04 s. The breakdown: loading Rails 3.1 s, hashing all 8,326 files 1.5 s,
the join by view names 2.3 s. After the fixes: 1.3 s. The run is repeated with
`/usr/bin/time -p` on the same commands.

**The rewritten queries were compared with the previous definitions by selecting
both ways** (`except` in both directions), not by "looks alike" and not by "the same
number of rows". Two cases, both with zero divergence: the rules about translation
keys (94 s → 0.6 s) and the summary of key accesses (1.5 s → 0.7 s).

**The gate before hashing was checked both in the live tree and by a spec.** In the
tree: an edit was noticed, a revert was noticed, someone else's edit (from another
session) was noticed. The spec checks both the saving and its safety — eight
examples.

**Two search engines were compared on one question**: 67 findings against 67, zero
divergence. Before the fix they diverged by five.

**The false-alarm rate was measured rather than assumed.** The document parse gave
137 "broken examples" on its first run; checking samples by eye showed fourteen were
real. The same with links: 632 → 15. The same with the rule about `rewrite … last`:
25 → 2. Every reduction was made as a separate named class, not as a threshold.

## Verified by inspection, 2026-10-09: four false findings of my own

The JavaScript and Stimulus parse was checked not by a report but by eye, finding by
finding. That gave the main result of the day: **four findings out of four turned out
to be parse errors rather than defects of the tree.** Each one is closed by an
example in a spec.

| the report claimed | checked by eye | the cause |
| --- | --- | --- |
| an action pointing at a method that does not exist | the method is there | a one-line value declaration swallowed the rest of the file |
| 11 targets are not declared | those are CSS selectors | a target name is an identifier, not a selector |
| 17 values are not set by the markup | all of them are set | the attribute body did not allow the other kind of quote, and it was inside ERB |
| an import leading nowhere | a `require` inside a string | that is how the source of a probe package is assembled |
| 3 controllers are activated by nobody | one of them is activated | activation comes in three kinds: markup, a Ruby helper, code at runtime |

After the repair: out of 2,809 actions, zero broken, zero unregistered activations,
zero undeclared targets, zero imports leading nowhere, zero dead files out of 248
"unreachable" ones. One real finding: `telegram-widget` is activated neither by
markup, nor by a helper, nor by code.

And separately — a check worth remembering: a quick regular expression over
controller names produced more than a dozen "used nowhere". The right answer is ONE,
and the path to it was "more than a dozen → 3 → 2 → 1", where every step removed one
way of being activated. The number from the quick check was never told to the owner.

## Verified by comparing sets, 2026-10-09: search instead of our own sweep

Three sweeps over the tree in Ruby (33 s, 11 s, 6 s) were replaced by `rg` (1.3 /
0.9 / 0.4 s); `bin/xref dead` — 80–140 s → 15 s. The check is not "it got faster"
but "does it answer the same": both answers were counted as sets and every
divergence explained one by one.

| what was compared | search | sweep | search only | sweep only |
| --- | ---: | ---: | ---: | ---: |
| route helpers | 1,254 | 1,246 | 8 | 0 |
| paths as strings | 9,668 | 10,119 | 412 | 863 |
| names with mentions (271 names) | 268 | 266 | 2 | 0 |

The divergences: the sweep does not read files larger than 4 MB (those hold machine
inventories — hence everything "search only", and that is the side where an error is
dangerous), and the search does not read binary files (hence the 863 paths — it was
verified that not one of them matches a route of the application, so the report's
answer does not change). Two further divergences were substitution errors and are
closed: the case-insensitivity flag does not live in the `source` of an expression
(6,064 paths instead of ten thousand), and a match at the start of a line has no
preceding character (902 paths).

## Measured, 2026-10-09: the false-finding rate by class

The only measurement of frequency we have, and it is about the tool itself. Seven
classes, checked against the first source one after another:

| class | the report said | real | false |
| --- | ---: | ---: | ---: |
| broken examples in documents | 137 | 7 | 95 % |
| broken links | 632 | 15 | 98 % |
| `rewrite … last` | 25 | 2 | 92 % |
| missing translations | 22 | 6 | 73 % |
| accesses to a column that does not exist | 13 | 4 | 69 % |
| dead Stimulus controllers | 3 | 1 | 67 % |

The conclusions that follow are in the specification (VI.3 and rule 16 of part
VII), and the mechanics are in the index: a verdict table, the filtering of
everything judged false out of the reports, and a reliability line next to every
class. The check of the mechanics itself:

- the verdict "false" removes a finding from the report — run on `texts` (6 → 3)
  and `docs` (14 broken links → 0), and the reason for each is visible in
  `bin/xref findings`;
- **an empty section explains its own zero through the journal**, rather than
  through the general caveat "this is an absence, not incompleteness": a zero that
  comes from filtering is a third case, and before the journal it did not exist;
- a verdict ages by the file's SHA, and that is the main thing: otherwise "false"
  hides a real problem that appeared later in the same place. For the classes with
  no file (a translation key, a table taken from a document) the anchor is the
  first calling file and the first document; one class was left with no anchor at
  all — an index in the database — and the report says of it "removed FOR GOOD";
- refining the filtering rule beats a verdict when the cause is shared: three of
  the seven unparsed examples turned out to be human notes (lines enumerated by
  number, a two-line quote from the middle of a hash, a one-line patch) — that is
  three new filtering classes and three examples in the specs, not three verdicts.

And one trap that sprang during this same work: rule 4 of part VII ("`squish` eats
SQL comments") I broke myself, in the very file of reports — a comment inside a
squished query ate the `group by`, and `bin/xref docs` died in the middle of its
work. Now it is a spec: among the squished queries of `lib/tasks/xref.rake` there
is not one `--`, and the guard was proven by removal (I planted a comment — the
spec failed and named the line).

## Verified by experiment, 2026-10-09: every command without a locale

A crash on encoding is a class that kills the WHOLE COMMAND, and it is not found by
reading. The run: `env -u LANG -u LC_ALL -u LC_CTYPE` on each of the twenty-seven
fast commands, with a non-Latin sample wherever a sample is possible.

**Two out of twenty-seven crashed:** `find` with a non-Latin pattern and `calls`
(the output of `git grep`). The cause is shared: bypassing Rails also bypasses
`Encoding.default_external = UTF-8` from `config/environment.rb`. Now zero crash;
the run is repeated with the same `env -u LANG …`, and as a single command —
`bin/xref locale` (a self-check, no database needed).

Two subtleties, each proven by removal:

- **`Encoding.default_external` does not fix the environment or the arguments** —
  those are stamped by the locale, and the locale does not change after the process
  starts; the value arrives as BINARY, and a `format` with non-Latin text next to it
  dies on that. The cure is restarting the process with `LC_ALL=C.UTF-8`;
- **the guard against looping is a check of what was done, not a mark in the
  environment.** With a mark (`XREF_LOCALE_FIXED=1`) the hole comes back the moment
  the mark leaks: verified, the crash came back exactly as before.

And the same class found outside the index — the cost of silence against the cost of
a crash. Of our 270 entry points, 213 read external bytes and check them, but only
one of those is live: `log-scanner` on the staging host. It read logs with
`File.foreach` with no encoding and swallowed the match error through `rescue
ArgumentError … next` — that is, **one broken byte cut off the rest of the log
silently**. The control experiment: a log of four lines with a broken byte in the
second, `status=500` and `status=503` in the third and fourth — the monitor for
500s found ZERO out of two, and reported green while doing so. After the fix, both.
Both guards are in that subsystem's specs and proven by removal.

## Verified by inspection, 2026-10-10: stylesheets and JavaScript, seven false findings of my own

The two new layers (stylesheets, JavaScript functions with their libraries) were
checked not by a report but finding by finding against the first source. The rate
held: **there were more false findings than real ones.**

| the report claimed | what is actually the case | the cause |
| --- | --- | --- |
| 4 stylesheets are included by nobody | 1 | three are included by an import FROM JAVASCRIPT and by a path assembled in the build config |
| `site_pages_tw.css` is dead | alive | its entry path is assembled from parts (`path.join(root, …)`), it has no key carrying the name |
| 11 `@import`s lead nowhere | 0 | all eleven are references to node_modules PACKAGES |
| `kind` is a style class | a variable | the class list has to be split on whitespace AFTER masking `<%= kind %>`, not before |
| 357 functions are dead | 0 in the application | the function is passed by value (`setTimeout(tick)`, `{ install: fn }`) |
| `errorMessageOption` is dead | it is called | `...fn()` is a spread, not a method access |
| the tree calls lodash as a global | it does not | `_(` lived inside a regular expression and a template string |

Plus **two errors in my own measurements**, caught the same way: any top-level
directory of views counted as a contour (five "contours" were invented that have no
layout of their own), and mentions were searched for in `app/` only, because of which
335 functions from `script/` read as dead.

What was checked against the first source in the opposite direction — so that the
findings would not be false "in the tool's favour": `accept` occurs in the tree 3,480
times and **not once inside `class=`** (it is `accept-charset`), `birthday` 239 times
and likewise never as a class. So the finding is real, and the quick check "the word
exists in the tree" is useless for this layer.

Each of the seven is closed by an example in a spec (`css_spec.rb`, `js_spec.rb`,
`code_scanner_spec.rb`). After the repair: one dead stylesheet, zero libraries with
no mention of their binding, zero `$(` in the application's JavaScript.

## Verified by a run, 2026-10-09: the query window from the database's own statistics

**The window grew from two days to eight, and that produced 67 tables** the index
had seen neither in the logs nor in the code parse. The source is pg_profile in the
first data centre: 336 snapshots of `pg_stat_statements` against two days of Puma
logs.

What was verified by execution rather than by reading:

- **an empty answer turned out to be a query error, not an absence of data.**
  Without `ON_ERROR_STOP=1` the database client exits zero on an error, and the
  report honestly said "0 patterns". Caught on the first run: the grouping by
  position in the concatenated string was wrong. The general lesson: **a zero in a
  new layer is the first thing to check**;
- **trimming the pattern invented a table.** A cut at 1,500 characters in the middle
  of a name gave `big_` instead of `big_users`, and that name travelled into "a
  table that exists in no schema". The cure is cutting at the last space, the rule is
  now one for both sources (`SqlRuntime.trim_tail`), and there is an example for it;
- **values never leave the node** — normalisation stands inside the query on the node
  itself, and there are no literals in the index. Verified on the output: the names
  with digits are intact, the values are gone;
- **the window is printed per source, separately.** The collection is configured in
  the first data centre only (eight days); the other two still have two. One shared
  number here would be a lie, and the report does not print one.

## Measured, 2026-10-10: live data — 3 tables → 28

The measurement of column fill rates went from 3 tables to **28 (820 columns)**,
and along the way two defects in the collector were found — both on the dangerous
side, "the table was left without a measurement while looking like one measured as
zeroes":

- **`interval` in the "has a value" condition.** The list of numeric types was a
  blacklist ("everything that is not text and not a date"), `orders.duration` fell
  onto it, and the query died. The list is now a whitelist;
- **one table killed the whole batch.** The same error on the first attempt aborted
  a run of 24 tables entirely: not one of them got measured. Now the error is caught
  per table, its text is remembered next to the result, and the run goes on.

The result that cannot be obtained without this measurement: **columns for which
BOTH proofs agree — empty in live data and with no reader in the code.** By the
measurement of 10-10 there are a couple of dozen (`profile_traits.trait_1…5`,
`legacy_sessions.last_page`, `notify_queue.payload` and others); the exact list
per table is printed by `bin/xref columns <table>`. The numbers here are
deliberately not rounded in the direction of confidence: the measurement covers 28
tables out of eight hundred, and outside them there is no answer.

## Verified by substitution, 2026-10-09: the habits of the tree take effect

Six lists of knowledge about OUR tree were moved into the configuration
(`idioms`). The check is not "the setting is read" but **the result of the parse
changes**: a spec substitutes the habits and compares the output. This is not
pedantry — we have already caught "a setting with no consumer": the list was moved
out and the place that read it was forgotten, and it looked like a working
improvement.

A second guard: the habits are part of the digest of the parse INPUTS. It was
verified that editing that section causes a re-parse of the tree with the files
unchanged — otherwise the report counts by the old rules and looks fresh.

## Verified by removal, 2026-10-10: the list of parse participants

The parser's digest is computed not over the whole tool directory but over the
PARTICIPANTS of the parse (otherwise editing a report costs 200 seconds of
re-parsing). That narrowing has a known dangerous side — "it narrowed silently" —
and there is a caveat against it: if a named file disappears, the digest is computed
over the whole directory.

**Proof-reading found a second hole of the same kind: the list is maintained by
hand, and `css.rb` never made it in.** For a day, editing the stylesheet parse rules
caused no re-parse at all, while the index looked fresh. Fixed, and the check no
longer rests on attentiveness: a spec derives the set of participants from whom
`code_scanner` actually calls and compares it with the declared list. The guard was
proven by removal — I took `css.rb` out of the list, the spec failed and named it;
put it back, green.

## Verified by removal, 2026-10-10: publishing the engine into the open repository

The engine was moved out into `../xref`, the transfer is done by
`script/xref-publish.sh`, and it has two refusals: an internal name in the public
copy (exit code 2) and a copied file that does not parse (exit code 3). Both were
proven by removal, and proving them found two holes in the guards — neither visible
by reading the code.

| what I did | what I expected | what I got |
| --- | --- | --- |
| planted `big_users_ghost` in the `css_spec.rb` fixture | a refusal with a line number | **the guard said nothing, exit code 0** — a word boundary at the end of the name (`\bbig_users\b`) does not match a compound form, an underscore being a word character |
| the same after removing the boundary | a refusal, code 2, line 17 of `css_spec.rb` | exactly that |
| replaced the name pattern itself with `ZZZ_NEVER_MATCHES` | the leak reaches the copy | it did: `../xref/spec/lib/xref/css_spec.rb:17` contains the planted name |
| added a stray `end` to `lib/xref/css.rb` | a refusal on the parse | a refusal, code 3, naming the file |
| removed the `publish_spec.rb` exclusion from the script | the spec fails | it failed and named the example |
| put the `\b` boundary back at the end of the name | the spec fails | it failed on the compound name |

**The second hole: the guard began refusing on its own list.** The publish spec holds
the names the engine was anonymised by, and the script copies `spec/` wholesale — the
publication dragged that list outside, and from then on the REFUSAL came on every run,
pointing at itself. The refusal was correct and useless. Now `publish_spec.rb` is not
published, and the spec checks that the exclusion is in place.

A third thing turned up along the way, this one not in a guard: the name pattern
gained `photos`, and the refusal immediately pointed at the `code_scanner_spec.rb`
fixture, where that name had stood from the very beginning — the anonymisation had
missed it, because the guard did not know about it. And then a refusal came on the
DESCRIPTION of this very lesson: in this section the names are said outright, and the
substitution list used when copying outside did not know two of them — now it does.
The guard, it turns out, guards the documentation too.

The transfer itself is checked by a spec (`spec/lib/xref/publish_spec.rb`, 14
examples): the cut marker stands exactly once, the tasks of that tree are below it,
the guard list has not gone empty, the pattern catches a compound name, and — when
`../xref` is checked out next to the tree — the engine files are identical to the byte
and the rake file differs only by the cut. The run: 318 examples in the tree, 304 in
the public copy (the difference is exactly that spec).

## Verified by execution, 2026-10-10: the English translation of the specification

The specification and this note were translated into English, and the translation
was checked the same way the Russian text was rather than by proof-reading: the
schema and the views out of the English document applied to a clean database
without a single error — **31 tables, 65 views, every one answering a `select`** —
and all **19 Ruby blocks** passed `ruby -c`. The numbers match the Russian ones,
which means not one line of code was lost while the comments were being
translated.

The latch against a stale translation was proven by removal: I corrupted the
checksum in the `<!-- translated-from: … -->` stamp — the publish step named the
document and printed the correct checksum; I put it back and it went quiet. It
shouts rather than refuses: a lagging translation is not a leak.

## Verified against the first source, 2026-10-10: what was leaking into the public copy

The owner's question was "does the structure of our database and the paths of our
project leak", and that question cannot be answered with a list of names I wrote
myself: a list goes stale. So the comparison started FROM THE FIRST SOURCE — from
the index itself.

**How it was measured.** Out of `lm_xref` came the names the tool knows about that
tree: **1,310 tables, 2,726 columns, 1,273 constants, 21,594 paths, 168 environment
key names, 37 nodes and services**. Out of all 69 tracked files of the public copy
came every identifier (`[A-Za-z_][A-Za-z0-9_]{3,}`) and every path, and the two sets
were intersected. The generic words (present in the system dictionary and carrying no
underscore) were separated from the distinctive ones by hand, one at a time.

**What was found, and it is not a trifle:**

| class | found | where |
| --- | --- | --- |
| names of our tables | **21 names in 105 places** | spec fixtures, engine comments, the specification |
| distinctive column names | 8 names | the same places plus part X |
| names of our classes | 5 | that application's models, SQL helper, columnar-store wrapper, protocol wrapper and cron registry |
| paths of our tree | 8 | examples in the tasks and in the specs |
| dangling references to an internal document | 12 | the internal note in the copies of the specs and of `bin/xref` |

And three findings that are worse than a leak, because they are also unportability —
**the names of one application were BAKED INTO THE ENGINE**: the registry of
scheduled jobs together with the key that names the environment, the protocol
wrapper of the columnar store, and the list of columns a recent cohort is counted
by. All three moved into
`idioms`, with the values in that tree's own `config/xref.yml` and generic defaults
in the engine. Verified by effect: after the move, collecting the application facts
again produced **89 jobs, every one of them with its places intact**.

Two more, found by the same comparison:

* **two columns of the index's own schema carried that application's jargon in
  their names**, while the published specification had always called them `places`
  and `env_id` — that is, the engine diverged from its own description. Renamed; an
  existing index database survives it by gaining the new columns;
* **an alias in the substitution list turned out to be one of our own columns**: one
  internal name was being replaced with another name that also exists in our schema.
  Replaced with an invented one — and it was the same deep check that found it, this
  time in my own description of the finding.

**The guard is now derived from the first source rather than from a list.** Before
publishing, `script/xref-publish.sh` asks the index which table names (longer than
six characters, carrying an underscore or a digit) and column names (longer than
eight, carrying an underscore) exist in our schemas, and looks for them in the copy;
long class names are asked for too (twelve characters and more — a shorter
constant is usually an ordinary English word, and refusing on those is how a guard
stops being read). A match is a REFUSAL with exit code 4. Generic names that are ours and universal at
once (`schema_migrations`, `table_name`, `created_at`, `scan_error`) are allowed BY
NAME — the list of decisions stays visible and small. With no index database at hand
the step says so out loud rather than keeping quiet.

Proven by removal, in both directions: a real table name from our snapshots planted
in a fixture produced a REFUSAL, exit code 4, with line numbers; with the check
switched off the same name travelled into the published spec. The publish spec checks
the mechanism itself (18 examples), and both new examples were proven by removal.

**What is left in the public copy, and why it is not a leak.** Not one of our table
names remains (three foreign ones do: `schema_migrations`, `pg_stat_statements` and
`countries`). Of the column names only the generic ones are left — `table_name`,
`user_id`, `created_at`, `lang`, `email` and the like, plus the index's own
vocabulary. Of the constants — English words (`Words`, `Check`, `Search`) and
framework names (`ApplicationRecord`, `ApplicationController`). Checked separately
and clean: no absolute paths (`/Users/…`), no IP addresses, of domains only
`example.com`, `example.org` and `github.com`, and no names of our nodes — the two
specs whose environments were named after real data centres now call them `prod_a`
and `prod_b`.

The limit of the comparison is stated honestly: columns shorter than eight characters
are not in the deep check — they cannot be told from ordinary words; environment key
names and translation keys are not compared at all; and the history of the public
repository was not proof-read line by line — it was replaced by a single clean commit
before anything was ever pushed.

## Verified by installing it, 2026-10-10: the tool works in another project without patches

The route now has three stations (the application → this repository → another
project), and it has one test: install it and run it.

**Installed** with a single `script/install.sh` into the project that used to keep
a file titled "my patches, restore after every update". Its copy of the engine was
a snapshot from 10-09: 19 library files and 8,227 lines against 28 and 10,468, with
no stylesheet layer, no front-end layer and not a single spec. After the install —
27 files plus the root, 22 spec files, and `diff -r` over `lib/xref` is empty.

**Run there, and this is the answer to "without rewriting":** its six TypeScript
patches are now in the engine, and its own check line confirmed it — `controllers
4, broken actions 0, unregistered activations 0, dead files 0`, exactly the numbers
its note records as "the patches are in place". Its list of declared environment
keys works through the new `env_declared` setting: "16 keys declared (from
`.env.example`)". Its "exactly `ru en`" works through `idioms.main_locales`.

**The two engine changes that made this possible were each verified separately:**

* `main_locales` — by substitution: with `[ru, en]` the report says every called key
  has both, with `[de]` it says "the key exists and there is no `de` translation:
  823". Before that the languages were baked into the `v_i18n_usage` view as two
  columns, and a tree with another pair would have patched the view and the report;
* `env_declared` — by a run in that project: 16 names out of a file, no values read.

**And a trap the same installation found:** a habit written at the TOP level of the
configuration (`locale_dirs:` instead of `idioms.locale_dirs`) is not read by the
engine — it looks like a working setting while the translations are collected from
the default directory. The engine now prints a warning about it on every run;
proven by removal — the setting moved out of the `idioms` section, the warning
appeared.

## Verified in the requester's own tree, 2026-10-10: reachability without a service inventory

The project the engine was installed into filed the first request upstream, and it
was a real defect — the kind only another tree can find:

**What it reported.** 19 JavaScript files, 11 import edges, and `reachable from an
entry point: 0`. Its two real build roots are named in its bundler config and were
already in the index as facts; the seed for reachability, however, was one
hardcoded path pattern — the layout of a different bundler.

**What was actually wrong went deeper.** Fixing the pattern alone changed nothing:
reachability is counted per place, the places come from the live service inventory,
and a project with no ssh to anything has none. Every cross join yielded nothing, so
every entry point of every kind disappeared — controllers and jobs included. The
report printed zeros about a tree whose graph was perfectly fine.

**What was changed.** The roots now come from the facts first (`js_entry` — what the
bundler's own config names) and from a configured pattern second
(`idioms.js_entry_paths`); the channel service is named by configuration too
(`idioms.channel_service_units`); and `v_places` gives one synthetic place when the
inventory is empty, while the audit says the places are not configured instead of
printing zeros.

**Measured in that project after the install: 0 → 13 reachable of 19 files**, and
the audit line now reads "the places are not described: reachability is counted in
one place". In the tree the engine lives in nothing was lost — the entry points grew
from the build roots the bundler config names. Four examples in the specs, proven by
removal.

The lesson is the one this project keeps relearning: a number that can only be zero
is not a measurement. "Reachable from an entry point: 0" with eleven import edges
right next to it was an answer about the tool, not about the tree.

## What was NOT verified

- the specification does not install with a command: it is a specification by which
  the tool is built, not a package. What was verified is that the schema and the views
  in it execute, and that the techniques are described with their reasons rather than
  as "this is how it is done";
- nothing was verified on another stack. The examples are Ruby and PostgreSQL; another
  language needs its own parser, and whether that parser has the properties required
  is an open question;
- we have no measurements of how often these problems occur IN A TREE, and the
  specification has none either. There are individual cases, each with a date and a
  number: that is not statistics. The one measurement of frequency is about the tool
  itself — the false-finding rate by class (the section above), and it is computed from
  the verification journal, that is, over those findings somebody checked by hand;
- **not all findings of the new layers were checked.** Checked: seven classes over
  documents, the front end, Stimulus, columns and translations, plus seven findings in
  stylesheets and JavaScript functions. NOT checked against the first source: 569
  classes "mentioned by nobody" (three names out of 569 were checked), 364 "a live
  document names a file that does not exist", 54 "a dangerous place in a script", 30 "a
  query in a document names a table that is not in the schema". By rule 16 those numbers
  are the tool's conjecture rather than findings, and that is how they were given to the
  owner;
- **the coverage of the measurements** is stated in numbers in the index and in part X
  of the specification, and that is not a verification but an honest boundary: live data
  measured for 28 tables out of eight hundred, the production-query window eight days
  for one source out of three, the contour provable for three template trees;
- **only two layers were ever checked on a foreign tree** (TypeScript extensions and
  environment keys via constants) — and both times defects turned up that are invisible
  on our own tree. The portability of the remaining layers is not verified by anything.

## How to run it yourself

```sh
# the schema and the views out of the specification — onto a clean database. Leading
# comments are stripped BEFORE the filter: otherwise the main schema block misses the
# filter and a view is the first thing to reach the empty database.
ruby -e 'doc = File.read("doc/guide.md")
         blocks = doc.scan(/```sql\n(.*?)```/m).flatten
         head = ->(b) { b.sub(/\A(?:\s*--[^\n]*\n|\s*\n)*/, "").downcase }
         File.write("/tmp/guide.sql", blocks.select { |b| head[b].start_with?("create") }.join("\n\n"))'
createdb probe && psql -q -v ON_ERROR_STOP=1 -d probe -f /tmp/guide.sql
# and ask EVERY view: applied is not the same as answers
psql -At -d probe -c "select table_name from information_schema.views where table_schema='public'" \
  | while read v; do psql -At -d probe -c "select count(*) from $v" >/dev/null || echo "ERROR in $v"; done

# the code fragments
for f in <the ruby blocks>; do ruby -c "$f"; done

# the log-parsing program — on four sample lines
printf '… Processing by ItemsController#index as HTML\n… Rendered home/_card.erb (1.0ms)\n…' | awk -f <the awk block>

# the tool itself: the specs and the encoding self-check (no database needed)
bundle exec rspec                   # 304 examples here, 318 in the tree it comes from
bin/xref locale                     # what ruby sees with no locale
env -u LANG -u LC_ALL -u LC_CTYPE bin/xref find "<a non-Latin pattern>"
```

In the tree the engine comes from there is one more command — `script/xref-publish.sh`,
the one-way transfer into this repository: two refusals, and otherwise a byte-for-byte
copy.

If something does not apply, it is a matter of the database version, and that is worth
saying rather than working around. Our versions: PostgreSQL 18.6 in production, 18.3 on
the developer's machine.

<!-- translated-from: doc/verification.ru.md sha256:c27954820452ddbcb6ccc811c026af9ee8649af5103dc3ca31be3b3ac9d365a7 -->
