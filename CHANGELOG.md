# Changelog

Dates are the dates things were measured, not release dates: this repository
publishes a tool that has been running inside a live application since
2026-08-21, and what matters about a change here is when its effect was observed.

## 2026-10-10 — the engine is published

The engine, the wrappers, the specs and the specification move out of the
application they grew in and into this repository. Nothing about them is new —
this is the first time they are standalone.

**What came out:** 28 library files (10,520 lines), the rake tasks and the
reports (4,828 — the two tasks of that application live in a rake file of their
own and never travel), 308 spec examples, the 3,900-line specification
(`doc/guide.ru.md`) and the verification note (`doc/verification.ru.md`).

**What the first standalone run found.** Running without an application, on a
foreign tree, was the actual test of portability. Six defects — and every one of
them was a defect in the original tree too, invisible there because that tree
always has a schema, always has templates and always has `bin/rails`:

1. **With no schema snapshot the index parsed no code at all.** The catch-up
   bailed out early with "run xref:schema first". Only one layer depends on
   schema names — the candidates by word; calls, renders, documents, styles,
   JavaScript and the dead-code sweep do not. A fresh installation with no source
   configured was refused answers the tool could give.
2. **`sum()` over an empty set killed a report.** `bin/xref audit` on an empty
   index died with `can't convert nil into Integer`. Twelve such sums now
   coalesce.
3. **The template-parse guard shouted at a project with no templates.** "Zero
   accesses out of templates means the template parse is broken" is true where
   templates exist; in a library it is a false alarm of exactly the kind the
   guard exists to prevent.
4. **Six commands called `bin/rails`, which a standalone installation does not
   have.** Collecting logs, queries, jsonb keys, services and live data needs no
   application at all; those are routed through the fast entry point. The two
   that genuinely need one say so instead of dying.
5. **`xref:app` died with `uninitialized constant Rails`** rather than naming
   what it needs — and what the index loses without it (no model map, so ORM
   accesses are not bound to tables).
6. **Four specs leaned on the tree they were running in** — two took a list of
   columnar-store wrappers from that project's configuration, one looked for a
   file in `app/javascript/`, one required Rails. A spec that is green in one
   tree and red in another proves nothing in either.

**Two things taken from the second project** that had vendored the engine before
this repository existed:

- **contracts declared in prose, and their latches** (`bin/xref rules`): a rule
  written in a document holds until the first careless edit and says nothing when
  it stops holding. The check asks three things — the document exists, the latch
  exists, and the latch *names* the subject of the contract. On its first run in
  the original tree it found a latch that lives only in an unmerged branch: the
  guard a document described as active does not run at all.
- **a file with a NUL byte is invisible to text search.** `rg` with our flags
  returns nothing and exits "not found"; `git grep` prints "Binary file …
  matches" instead of the lines, and an output parser throws that away. The file
  passes `ruby -c` and the linter. In that project a live service sat like that,
  answering no search, and was found by eye. The index knows such files (the
  parse reads them) and now says so: `v_search_blind`, a line in `audit` and a
  line in `find`.

**Also in this release**, from the same week inside the original tree:

- **stylesheets became a layer** (`bin/xref css`): declared classes, `@import`
  resolution, `@apply`, and from the markup side literals, `classList`/`addClass`
  and Stimulus class attributes. The layer's own blindness is printed first: in
  that tree a class name is assembled in full in 2,421 places, so "nothing
  mentions this class" is a lower bound rather than a verdict. Seven false
  findings were killed before publication, four of them by adding the ways a
  stylesheet stays alive (a bundler entry, an import from JavaScript, a path
  assembled in the build config);
- **top-level JavaScript functions and library calls** (`bin/xref js`): 357
  "dead" functions came down to zero in the application — a function is passed by
  value, exported, called from a script outside the app. Libraries are counted
  through their import bindings: the tool does not go inside a library, because
  "unused" is the majority in there by construction;
- **queries that ran, from the database's own statistics** (`bin/xref sql
  profile`): the observation window went from two days to eight and brought 67
  tables the index had never seen. Nothing has to be enabled in production — the
  statistics are either already collected or the logs are used;
- **the verdict journal** (`bin/xref findings` / `bin/xref verdict`): what was
  verified against the first source, what turned out false, and the
  false-positive rate printed next to every class of finding. The measurement
  behind it: in a new layer false findings outnumber real ones two or three to
  one;
- **the habits of a tree moved into configuration** (`idioms:`): which methods
  fetch a result row, what such a variable is called, which wrappers take a table
  as their first argument. Baked into the parser they were what made the tool
  unportable;
- **every command survives a missing locale.** Without `LANG` Ruby assumes
  US-ASCII and the first non-Latin letter kills the whole command — not one
  finding, the entire report. Two of twenty-seven commands died that way, found
  by running all of them with the locale stripped rather than by reading code.

**Installing into a project is one command, and the differences between projects
are settings.** `script/install.sh <tree>` copies the engine, the rake file, the
wrapper and the specs into a tree, rewrites the single `require` line in the
specs, updates the Russian copies of the documentation if that tree keeps them —
and never touches `config/xref.yml`. The route now has three stations: the
application the engine grew in → this repository → any other project.

That middle station is what the release is about. The project that vendored this
engine before the repository existed had to copy it out of the application tree
and patch it, and kept a file listing every patch so it could restore them after
each update — twice an update had carried them away silently. That list is now a
list of settings: TypeScript extensions, contract latches, environment keys held
in constants, the system-set variables the environment report must not accuse the
code of (`idioms.standard_env`), a file of declared keys (`env_declared`), the
languages a translation key must exist in (`idioms.main_locales`), where the
translations live, the cron registry and the key inside it that names an
environment, the columnar-store protocol wrapper, the columns a recent cohort is
counted by. The one thing still local there is a small command-line wrapper of
its own.

**And the install delivers a skill**, because a tool nobody asks is a tool nobody
has: in both trees that use this engine, neither their instructions nor any skill
mentioned `bin/xref`, and a fresh agent session reached for a text search every
time. `skills/xref/SKILL.md` is what an agent matches against — when to ask the
index instead of grepping, how to read a fact against a candidate against a guess,
and the three rules that make an answer worth quoting (ask on a clean tree; a
finding is a candidate until checked against the first source, and the check gets
recorded; numbers age). It goes to the root of the tree being indexed, because that
is where an agent looks for skills — not into the tool's own directory, where the
first version of this step would have left it invisible.

Three mechanisms made that possible, and each closed a real failure:

- **the wrapper is no longer a closed list.** `bin/xref <name>` passes an unknown
  command on as `xref:<name>`, so a project adds reports of its own in a separate
  rake file instead of patching the engine. The application the engine grew in
  does exactly that with its two tasks about its own interface contour — which is
  also why the engine's rake file no longer needs to be cut at a marker on every
  publish;
- **two baked-in languages became a setting.** The translation view carried
  `has_en`/`has_ru` columns, so a tree with another main pair had to patch the
  view and the report. The view now returns the list of languages per key and the
  report asks `idioms.main_locales`. Proven by substitution: with one pair the
  report says every called key has both, with another it names 823 gaps;
- **a habit written at the top level of the configuration is said out loud.** One
  project kept `locale_dirs:` outside the `idioms` section, the engine read
  `idioms.locale_dirs`, and the translations were collected from the default
  directory while the file said otherwise — a setting with no effect that looks
  exactly like one that works.

**The specification is in English.** `doc/guide.md` (4,161 lines) and
`doc/verification.md` are translations of the Russian copies, and the copies stay —
they are generated mechanically by the publish step and cannot go stale. The
translation is verified the same way the Russian text was: the schema and the views
out of the English document apply to a clean database with zero errors (31 tables,
65 views, every one answering a `select`) and all 19 Ruby blocks pass `ruby -c`.
Each English document carries the checksum of the Russian copy it was translated
from, and the publish step says out loud when a translation has fallen behind. A
few words stay in Russian on purpose — the values the tool prints into its reports
— and each is glossed where it appears.

**How a change travels from now on.** Edits happen in the tree the engine grew
in — that is where it is exercised against live databases, production logs and
real data — and `script/xref-publish.sh` carries them here: a byte-for-byte copy
of the engine, the application-specific tasks cut off at a marker, and two
refusals (an internal name in the copy, a copied file that does not parse). Both
refusals were proven by removing them, which found two holes in the guard itself:
a word boundary at the end of a name made it blind to compound names, and the
check began refusing on its own list of names. `doc/workflow.md` is the whole
procedure, including how to take a change into a vendored copy and send one back.

## Earlier

The engine was grown inside one application from 2026-08-21 onwards. Its history
is not reproduced here; what that history produced is the specification —
`doc/guide.ru.md`, where every rule carries the failure it came from — and the
verification note, `doc/verification.ru.md`, which says what was checked by
execution and what was never checked at all.
