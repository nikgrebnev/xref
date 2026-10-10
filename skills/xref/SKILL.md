---
name: xref
description: Ask the local code index before reaching for a text search. Use it for questions about this tree — where a table or a column is touched, what an edit will affect, who calls a method, which routes, actions, templates, styles or JavaScript functions are unused, which queries actually ran in production, which environment is missing a table, what gets interpolated into a query and where that text comes from, which fields are read nowhere and empty in the live data. `bin/xref` answers in about a second, keeps facts apart from candidates, and prints what it cannot see before what it found.
---

# xref: ask the index, then read the code

`bin/xref` is a local database of facts about this tree and about the
environments it runs in. It is not a faster grep — it is grep plus meaning: to
every hit it adds what a text search cannot know (is the file reachable from
production and from what depth, who calls it, which tables it touches, how many
blind spots it holds, whether it was rendered in the live logs).

Run `bin/xref help` first in an unfamiliar tree: the command list is the
authority, this file is the habit.

## Ask it before a text search

| the question | the command |
| --- | --- |
| where is this table or column touched | `bin/xref where users.email` |
| in which tables and environments does a column live | `bin/xref column paid_` |
| what will this edit affect | `bin/xref changed [ref]` |
| what to read before editing this file | `bin/xref boundary <file>` |
| from a task to the files, in reading order | `bin/xref scope "<task>"` |
| who calls this method, and what they pass | `bin/xref calls <method>` |
| who reaches this file | `bin/xref callers <file>` |
| which routes, actions, controllers, methods are unused | `bin/xref dead` |
| which environment is missing a table the code reaches for | `bin/xref blind` |
| how the environments' schemas differ | `bin/xref drift` / `bin/xref migrations` |
| what is interpolated into a query, and where the text comes from | `bin/xref holes [name]` |
| which queries actually RAN | `bin/xref sql` / `bin/xref sql profile` |
| which templates and actions ran in production | `bin/xref views` |
| which columns are read nowhere — and empty in the data | `bin/xref columns <table>` / `bin/xref fill <table>` |
| environment keys: read by the code, absent from the environment | `bin/xref env` |
| texts: a key is called and has no translation, and the reverse | `bin/xref texts` |
| documents, front-end config, styles, JavaScript | `bin/xref docs` / `front` / `css` / `js` |
| text search, enriched by everything above | `bin/xref find "<pattern>"` |
| what the index knows and what it does not | `bin/xref audit` |

Anything not on the list is passed on as a rake task of the same name, so a tree
can add reports of its own: `bin/rails -T xref` shows what this one declares.

## Read the answer the way it is written

**A fact, a candidate and a guess sit in different sections.** A parsed query
yields a fact; a name met in text is a candidate; a table name assembled at
runtime is a guess. Do not quote a candidate as if it were a fact.

**The blind spots come first, and they are the measure of the answer.** "Nobody
mentions this class" from a layer that also reports "a class name is assembled in
full in 2,421 places" is a lower bound, not a verdict.

**An empty answer explains itself.** "Zero under a full parse" and "zero while
the SQL parser was unavailable" are printed in different words — read which one
you got.

## Three rules that make the answers worth anything

1. **Ask on a clean tree.** The index sees files tracked by git, so during work in
   flight it answers half-truths: a new untracked file is invisible while an edit
   in a tracked one is not. `FULL=1` does not help and should not.
2. **A finding is a candidate until checked against the first source** — the
   schema, the data, the logs, a spec, or your own eyes. In a layer that has just
   appeared, false findings outnumber real ones two or three to one; that is
   measured, not feared. When you have checked one, record it:
   `bin/xref verdict <class> <subject> false|real "why" [how]` — then the next
   report does not show it again, and `bin/xref findings` prints the share of
   false ones per class so a new finding can be weighed.
3. **Numbers age.** Every number in a report is an observation with a date. Quote
   the command next to the number rather than the number alone.

## If the tool is not installed, or something is missing

Install it from its own repository, in one command, and never patch the installed
files — the next install overwrites them silently:

```sh
<path-to-xref-repo>/script/install.sh <this-tree>
```

Everything this tree does differently belongs in `config/xref.yml` — the `idioms`
section describes the habits of a tree (which methods fetch a result row, what
such a variable is called, which wrappers take a table as their first argument,
which languages a translation key must exist in, where the translations live).
A habit written outside the `idioms` section is not read; the tool says so.

If something about this tree cannot be said in the configuration, that is a defect
of the engine rather than of the tree: say so to the owner instead of patching the
copy.

## What to read

- `doc/guide.md` — the specification: the storage schema, the record contracts and,
  next to every rule, the failure it came from;
- `doc/verification.md` — what was checked by execution, and an honest list of what
  was never checked;
- `doc/workflow.md` — how a change travels between the copies.
