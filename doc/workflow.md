# Where the code lives and how a change travels

The route is one-way and it has three stations:

| station | what it is | who edits it |
| --- | --- | --- |
| **the application the engine grew in** | 600,000 lines; the engine sits inside it and is exercised against five live databases, production logs and real data | the author |
| **this repository** | the same engine, standalone: its own bundle, no application. The copy the world sees | published from the application, one way |
| **any other project** | the engine installed from here with `script/install.sh` | that project's author — in its configuration, never in the code |

Three copies of anything drift apart. They drift apart *silently*, which is the
exact failure this tool was built to catch — so both steps are mechanical, and
the first one refuses to finish when the result is wrong.

**The middle station is the point.** Before it existed, a second project had to
copy the engine out of the application tree and patch it: a difference between
projects became a local change, and a local change is what an update carries
away. That happened twice, and the project kept a file listing every patch so it
could restore them after each update. Now a difference between projects is a
SETTING — `config/xref.yml`, the `idioms` section: which methods fetch a result
row, what such a variable is called, which wrappers take a table as their first
argument, which constant holds the cron schedule, which columns a recent cohort
is counted by, which languages a translation key must exist in, where the
translations live. That project's list of patches is now a list of settings, and
the engine is identical in all three places.

## Installing into a project

```sh
script/install.sh /path/to/your-tree
```

It copies the engine, the rake file, the wrapper and the specs; rewrites the one
`require` line in the specs (`rails_helper` in a Rails tree, `spec_helper`
standalone); updates the Russian copies of the documentation if the target keeps
them under its own names; and **never touches `config/xref.yml`** — that file is
the target's own, and its hosts and habits live there. Every copied file is
checked to parse where it landed.

A project adds reports of its own without editing the engine: put them in a
separate rake file inside `namespace :xref`, and `bin/xref <name>` passes an
unknown command on as `xref:<name>`. The application the engine grew in does
exactly that with its two tasks about its own interface contour.

The install also delivers the **skill** (`skills/xref/SKILL.md` → the tree's
`.claude/skills/xref/`). That is not decoration: the tool is only worth anything
if it gets ASKED instead of a text search, and in both trees that use it nothing
pointed a fresh session at it — neither their instructions nor any skill
mentioned `bin/xref`. The complaint written down in one of them was exactly that:
"installed it once, in the session that installed it, and the next one reaches for
grep". Where the tool sits beside the tree it indexes, the skill goes to THAT
tree's root — an agent looks for skills under the project, not under the tool.
`XREF_SKILL=global` puts it in `~/.claude/skills` instead (for a tree that must not
gain an untracked file), `XREF_SKILL=none` skips it.

## The rule

**The engine files are byte-identical in every copy.** `lib/xref.rb`,
`lib/xref/*.rb`, `lib/tasks/xref.rake`, `bin/xref`, `bin/xref-run`,
`spec/lib/xref/*_spec.rb` — all the same bytes. That is what makes a comparison
trivial: `diff -r` is the whole verification. Anything that cannot be identical
is not an engine file.

One line is deliberately not identical: a spec starts with `require
'rails_helper'` inside an application's suite and `require 'spec_helper'`
standalone. Both transfer steps rewrite that line and nothing else.

The rake file used to be the exception too — it carried two tasks belonging to
the application the engine grew in, and was cut at a marker on every publish. A
cut is a thing that can start eating a line of the generic part unnoticed, so
those tasks moved into a rake file of their own, which never travels. The engine
travels whole.

Three things are only here, because they describe an installation rather than an
engine: `config/xref.yml`, `config/xref.example.yml`, `Gemfile`. And one spec
stays in the application: it is about the transfer itself, and it holds the list
of internal names the publish step refuses on — publishing it would carry that
list into this repository and make the guard refuse for ever, pointing at itself.

## The documentation: the copy is generated, the original is translated

The two documents are the one place where "the original" and "the copy" point in
opposite directions, so it is worth saying plainly:

- `doc/guide.ru.md` and `doc/verification.ru.md` are **generated** by the publish
  step out of the tree the engine comes from, with the internal names substituted.
  They cannot go stale, and they must not be edited here — the next publish would
  overwrite the edit;
- `doc/guide.md` and `doc/verification.md` are **translated by hand** from those
  copies. A translation cannot be regenerated, so it can only rot — silently,
  which is the failure this whole arrangement exists to prevent.

Hence the latch: every English document ends with the checksum of the Russian copy
it was translated from.

```
<!-- translated-from: doc/guide.ru.md sha256:… -->
```

The publish step compares that line with the copy it has just generated and, on a
mismatch, says out loud which translation has fallen behind and prints the new
checksum to put in its place. It warns rather than refuses: refusing would block a
publish over a documentation lag, and a lag is not a leak.

A few words in the English documents are deliberately left in Russian — the values
the running tool prints into its reports and its views (verdicts, classes of
finding, the strength of a link). They are values, not keywords; translating them
in the documentation would make the view definitions differ from the ones the
engine actually creates. Every one of them is glossed where it appears.

## Publishing (tree → here)

One command in the tree:

```sh
script/xref-publish.sh ../xref
```

It copies the engine whole, rewrites the one `require` line in the specs, copies
the documentation with the internal names substituted, and then **refuses** on
any of three checks:

- an internal name reached the public copy (a table, a host, a theme of that
  application) — the pattern list is the one the engine was anonymised by;
- a name out of that application's OWN SCHEMAS reached the copy — the deep
  check, which asks its index rather than a list, because a list is kept by hand
  and hands go stale. The audit of 2026-10-10 found 21 table names, 8 column
  names and 5 class names that the hand-kept list knew nothing about;
- a copied file does not parse.

On its first run it refused seven times: five spec fixtures and two comments
still carried internal names. That is what the guard is for — a leak found by a
script before publication beats one found by a reader afterwards.

Both refusals are proven the way this project proves any guard — **by removing
it**: a name planted in a fixture must stop the publish (and, with the guard
switched off, must visibly reach the copy); a stray `end` added to a library file
must stop it too. Doing that found two holes in the guard itself, neither of
which was visible by reading it:

1. **A word boundary at the END of a name switched the guard off for compound
   names.** An underscore is a word character, so `\bbig_users\b` does not match
   `big_users_live` — and the compound forms are exactly the ones that leak. A
   planted compound name went through untouched. The trailing boundary is gone,
   and the spec now asks the pattern itself rather than asking a reader.
2. **The guard began refusing on its own list** — the mechanism described two
   paragraphs above. It refused correctly and uselessly: every run, on the same
   line, about a name that was only there to describe the check.

## Taking a change into your own tree

One command, from this repository:

```sh
script/install.sh /path/to/your-tree
```

Your `config/xref.yml` is never touched. Everything your tree does differently
belongs in it — and if something cannot be expressed there, say so in an issue:
a difference that has to live in patched code is a defect of this repository,
not of your tree. That is not a slogan but a measured lesson:

> An update twice carried away local adaptations silently. It looked like "the
> tool got updated" and it was in fact "a check got switched off".

The project that lost them kept a file listing every local patch with the reason
for it, and after each update it restored them by hand. That file is now a list
of settings — TypeScript extensions, contract latches, the names of environment
keys held in constants, the list of system-set variables, the declared-keys file,
the main languages — and the one thing still local there is a small command-line
wrapper of its own.

## Sending a change back

Open a pull request against this repository. Two things make a change easy to
accept, and they are the project's own rules applied to itself:

1. **An example that fails without the change.** Every spec in
   `spec/lib/xref/` exists because something was once wrong; a new rule with no
   example is a rule nobody will dare touch later.
2. **The reason in a comment, with its number.** Not what the code does — why
   this rule and not the obvious one. "Without this branch the report called
   eleven live build lines broken" is worth ten lines of description of the
   regexp.

A change accepted here lands in the application tree by hand (that is where it
gets exercised against live data), and the next publish makes the copies
identical again — which the application's own spec checks, file for file.

## What is measured, not claimed

- the engine: 28 files, 10,520 lines; the tasks and the reports 4,828 more, and
  they travel whole — the 500 lines of the application's own two tasks are not in
  this file at all;
- the specs: 308 examples here in 22 files, 329 in the application tree — the 21
  extra ones are the transfer check, which has nothing to test on this side;
- the specification: 4,161 lines in English, 3,949 in the Russian copy. The schema
  and the views in the English text were applied to a clean database the same way
  as in the Russian one — 31 tables, 65 views, every one answering a `select`, and
  all 19 Ruby blocks pass `ruby -c`. Here two of them are
  pending rather than green: one needs a loaded application, one needs the index
  database. A skipped check is an unanswered question, so they say what they
  need;
- the first standalone run — the whole point of this repository — found six
  portability defects in the engine, every one of which was a defect in the
  original tree as well. They are listed in the CHANGELOG.
