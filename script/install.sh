#!/bin/sh
# Install the engine from THIS repository into a project tree.
#
# WHERE THIS REPOSITORY SITS IN THE ROUTE. The engine is written and exercised
# inside the application it grew in — five live databases, production logs, real
# data — and published FROM there INTO this repository. This repository is the
# copy the world sees, and it is also the station every other project installs
# from: that is what this script is for. Nobody copies the engine out of the
# application tree by hand.
#
# The point of the middle station is that another project can use the tool
# WITHOUT REWRITING IT. A difference between projects goes into
# `config/xref.yml` — the `idioms` section describes the habits of a tree: which
# methods fetch a result row, which wrappers take a table as their first
# argument, which constant holds the cron schedule, which columns a recent cohort
# is counted by. A difference that lives in patched code instead is what an
# update silently carries away: that happened twice in the project that vendored
# this engine before the repository existed.
#
# What travels:
#
#   lib/xref.rb, lib/xref/*.rb        the engine
#   lib/tasks/xref.rake               the tasks and the reports
#   bin/xref, bin/xref-run            the wrapper and the fast entry point
#   spec/lib/xref/*_spec.rb           the examples (`rails_helper` in a Rails tree)
#   doc/guide.ru.md, verification.ru.md   into the target's own doc names, if it has them
#   skills/xref/SKILL.md              into .claude/skills/xref/ — so a session finds the tool
#
# What NEVER travels, because it belongs to the target:
#
#   config/xref.yml                   its hosts, its sources, the habits of its tree
#   anything else in the target       its own tasks, its own wrappers, its notes
#
# A tree may hold tasks of its own in a separate rake file (`lib/tasks/*.rake`
# inside `namespace :xref`): `bin/xref <name>` passes an unknown command on as
# `xref:<name>`, so a project adds reports without editing the engine.
#
# Usage: script/install.sh <target-tree>
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
target="${1:-}"
[ -n "$target" ] || { echo "нужен каталог дерева: script/install.sh <путь>" >&2; exit 1; }
[ -d "$target" ] || { echo "нет каталога $target" >&2; exit 1; }
[ -f "$here/lib/xref.rb" ] || { echo "запускать из репозитория xref" >&2; exit 1; }

case "$target" in /*) ;; *) target=$(cd "$target" && pwd) ;; esac
[ "$target" = "$here" ] && { echo "это и есть репозиторий инструмента, ставить его в себя нечего" >&2; exit 1; }

# A Rails tree runs the examples inside its own suite; a standalone installation
# has this repository's spec_helper. The one `require` line is the only
# difference between the two copies of a spec.
helper="spec_helper"
[ -f "$target/bin/rails" ] && helper="rails_helper"

echo "== ставлю движок в $target (спеки через $helper)"
mkdir -p "$target/lib/xref" "$target/lib/tasks" "$target/bin" "$target/spec/lib/xref"

cp "$here/lib/xref.rb" "$target/lib/xref.rb"
cp "$here"/lib/xref/*.rb "$target/lib/xref/"
cp "$here/lib/tasks/xref.rake" "$target/lib/tasks/xref.rake"
cp "$here/bin/xref" "$here/bin/xref-run" "$target/bin/"
chmod +x "$target/bin/xref" "$target/bin/xref-run"

for spec in "$here"/spec/lib/xref/*_spec.rb; do
  sed "s/^require 'spec_helper'$/require '$helper'/" "$spec" \
    > "$target/spec/lib/xref/$(basename "$spec")"
done

# A standalone target needs the helper itself; a Rails tree has its own.
if [ "$helper" = "spec_helper" ] && [ -f "$here/spec/spec_helper.rb" ]; then
  cp "$here/spec/spec_helper.rb" "$target/spec/spec_helper.rb"
fi

# THE CONFIGURATION IS NEVER OVERWRITTEN. A tree that has none gets the minimal
# one once, so that the first command answers something; a tree that has one
# keeps it, because its hosts and the habits of its code live there.
if [ ! -f "$target/config/xref.yml" ]; then
  mkdir -p "$target/config"
  cp "$here/config/xref.yml" "$target/config/xref.yml"
  # The documented template goes with the FIRST installation only: a tree that
  # already has its configuration has already read it, and a second copy of a
  # document is a second copy to drift.
  cp "$here/config/xref.example.yml" "$target/config/xref.example.yml" 2>/dev/null || true
  echo "   config/xref.yml — поставлен минимальный, рядом xref.example.yml с описаниями"
else
  echo "   config/xref.yml — оставлен как есть"
fi

# The Russian copies of the documentation go into whatever the target already
# calls them: a tree that keeps `doc/xref-guide.md` gets its copy updated, a tree
# that has no such file is left alone rather than littered.
for pair in "doc/guide.ru.md:doc/xref-guide.md" "doc/verification.ru.md:doc/xref-verification.md"; do
  src="$here/${pair%%:*}"
  dst="$target/${pair##*:}"
  if [ -f "$src" ] && [ -f "$dst" ]; then
    cp "$src" "$dst"
    echo "   ${pair##*:} — обновлён из ${pair%%:*}"
  fi
done

# THE SKILL. The tool's value is that it gets ASKED instead of a text search, and
# a fresh session has no way of knowing it exists: in both trees that use it,
# neither CLAUDE.md nor any skill mentioned `bin/xref`, and the complaint written
# down in one of them was exactly that — "installed it once, in the session that
# installed it, and the next one reaches for grep". A skill is what an agent
# matches against by its description, so it lands where the agent looks for it.
#
# It is a copy like everything else: edited here, overwritten on the next install.
# WHERE it goes matters more than it looks: an agent looks for skills under the
# PROJECT's root, not under the tool's directory. Where the tool sits beside the
# tree it indexes (`project_root` in its configuration), the skill belongs to that
# tree — otherwise it lands in a directory nobody looks into. Measured the dull
# way: the first run put it two levels below the project and it would have been
# invisible.
#
#   XREF_SKILL=global  — into ~/.claude/skills instead, for a tree that must not
#                        gain an untracked file;
#   XREF_SKILL=none    — do not install it at all.
if [ -f "$here/skills/xref/SKILL.md" ] && [ "${XREF_SKILL:-tree}" != "none" ]; then
  if [ "${XREF_SKILL:-tree}" = "global" ]; then
    skill_root="$HOME"
  else
    skill_root="$target"
    indexed=$(sed -n 's/^project_root:[[:space:]]*//p' "$target/config/xref.yml" 2>/dev/null | head -1)
    if [ -n "$indexed" ]; then
      case "$indexed" in /*) skill_root="$indexed" ;; *) skill_root=$(cd "$target/$indexed" 2>/dev/null && pwd || echo "$target") ;; esac
    fi
  fi
  mkdir -p "$skill_root/.claude/skills/xref"
  cp "$here/skills/xref/SKILL.md" "$skill_root/.claude/skills/xref/SKILL.md"
  echo "   навык: $skill_root/.claude/skills/xref/SKILL.md — сессия найдёт инструмент сама"
fi

# Every copied file has to parse where it landed: a tree with an older ruby is a
# real case, and a copy that does not parse must be visible now rather than on
# the first report.
for file in "$target"/lib/xref.rb "$target"/lib/xref/*.rb "$target"/lib/tasks/xref.rake \
            "$target"/spec/lib/xref/*.rb; do
  ruby -c "$file" > /dev/null || { echo "ОТКАЗ: не разбирается $file" >&2; exit 3; }
done
sh -n "$target/bin/xref" || { echo "ОТКАЗ: не разбирается bin/xref" >&2; exit 3; }
ruby -c "$target/bin/xref-run" > /dev/null || { echo "ОТКАЗ: не разбирается bin/xref-run" >&2; exit 3; }

engine=$(cat "$target"/lib/xref.rb "$target"/lib/xref/*.rb | wc -l | tr -d ' ')
tasks=$(wc -l < "$target/lib/tasks/xref.rake" | tr -d ' ')
specs=$(cat "$target"/spec/lib/xref/*_spec.rb | wc -l | tr -d ' ')
echo "   движок $engine строк, задачи $tasks, спеки $specs — все файлы разбираются"
echo "== готово. Что изменилось в $target:"
git -C "$target" status --short -- lib/xref lib/tasks/xref.rake bin/xref bin/xref-run spec/lib/xref doc 2>/dev/null || true
