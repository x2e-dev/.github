#!/usr/bin/env bash
# PR guard for x2e-dev. Enforces AGENTS.md rules 2-4, 7 and 9 in CI while the org is on GitHub Free
# and the repositories are private (no rulesets, required reviews or merge queue until M4).
# Usage: pr-guard.sh check      (in CI; needs GH_TOKEN, REPO, PR, OWNER, PROTECTED)
#        pr-guard.sh self-test  (local)
set -euo pipefail

# Golden frames under test/frames/ are written by the test runner and read by eye, as a lockfile is
# written by the package manager (owner's decision, 2026-11-03): a layout change moves every frame.
export GENERATED_RE='(^|/)(pnpm-lock\.yaml|package-lock\.json|Cargo\.lock|bun\.lockb?)$|(^|/)generated/|\.gen\.|(^|/)test/frames/'
SOFT_LIMIT=400
HARD_LIMIT=1000

check_title() { [[ $1 =~ ^(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?:\ .+ ]]; }

# stdin: filename<TAB>additions<TAB>deletions; prints changed lines outside generated files and
# outside SIZE_EXEMPT, a repository's own vendored data (library's mirrored items/, owner 2026-11-06)
count_lines() {
  awk -F'\t' '$1 !~ ENVIRON["GENERATED_RE"] && (ENVIRON["SIZE_EXEMPT"] == "" || $1 !~ ENVIRON["SIZE_EXEMPT"]) { n += $2 + $3 } END { print n + 0 }'
}

# exactly one provenance trailer per commit message; $2=any accepts one or more, for imported
# history whose squash commits carry several Agent-Session lines (size-exempt, zoryax#2083)
provenance_ok() {
  local a h
  a=$(grep -cE '^Agent-Session: .+' <<<"$1" || true)
  h=$(grep -cE '^Human-Authored: .+' <<<"$1" || true)
  if [ "${2:-}" = any ]; then [ $((a + h)) -ge 1 ]; else [ $((a + h)) -eq 1 ]; fi
}

# stdin: event<TAB>label<TAB>actor of a PR's issue events; true when $OWNER added label $1
labeled_by_owner() {
  awk -F'\t' -v l="$1" -v o="$OWNER" 'o != "" && $1 == "labeled" && $2 == l && $3 == o { f = 1 } END { exit !f }'
}

# stdin: filenames; $1: newline-separated glob patterns ('*' also matches '/')
touches_protected() {
  local f p
  while IFS= read -r f; do
    while IFS= read -r p; do
      [ -n "$p" ] && [[ $f == $p ]] && return 0
    done <<<"$1"
  done
  return 1
}

check() {
  local errors=() warnings=() title files lines
  title=$(gh api "repos/$REPO/pulls/$PR" --jq .title)
  check_title "$title" || errors+=("PR title is not Conventional Commits: '$title'")

  # Labels count only when the owner's account added them. Caveat: agents that act with the owner's
  # token are indistinguishable from the owner; give agents their own GitHub App identity (infra/README.md).
  local events
  events=$(gh api --paginate "repos/$REPO/issues/$PR/events" --jq '.[] | [.event, .label.name // "", .actor.login // ""] | @tsv')
  owner_labeled() { labeled_by_owner "$1" <<<"$events"; }

  # size-exempt: a one-time move of a whole tree with its history (owner, 2026-11-26, zoryax#2083)
  local exempt=""
  owner_labeled size-exempt && exempt=any

  files=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[] | [.filename, .additions, .deletions] | @tsv')
  lines=$(count_lines <<<"$files")
  if [ -n "$exempt" ]; then warnings+=("size-exempt by @$OWNER: $lines lines, size limits lifted, one or more trailers accepted")
  elif [ "$lines" -gt "$HARD_LIMIT" ]; then errors+=("PR changes $lines lines (> $HARD_LIMIT); split it")
  elif [ "$lines" -gt "$SOFT_LIMIT" ]; then warnings+=("PR changes $lines lines (> $SOFT_LIMIT); explain why in the description"); fi

  while read -r sha msg64; do
    provenance_ok "$(base64 -d <<<"$msg64")" "$exempt" || errors+=("commit ${sha:0:7} needs exactly one trailer: 'Agent-Session: <id>' or 'Human-Authored: yes'")
  done < <(gh api --paginate "repos/$REPO/pulls/$PR/commits" --jq '.[] | "\(.sha) \(.commit.message | @base64)"')

  if cut -f1 <<<"$files" | touches_protected "${PROTECTED:-}"; then
    owner_labeled owner-approved || errors+=("protected paths changed: needs label 'owner-approved' added by @$OWNER")
  fi
  if gh api "repos/$REPO/issues/$PR/labels" --jq '.[].name' | grep -qx scope-expanding; then
    owner_labeled scope-approved || errors+=("scope-expanding PR needs label 'scope-approved' added by @$OWNER")
  fi

  local out=${GITHUB_STEP_SUMMARY:-/dev/stdout} e w
  { echo "### pr-guard: $lines changed lines"; for w in "${warnings[@]}"; do echo "- warning: $w"; done
    for e in "${errors[@]}"; do echo "- error: $e"; done; } >>"$out"
  for w in "${warnings[@]}"; do echo "::warning::$w"; done
  for e in "${errors[@]}"; do echo "::error::$e"; done
  [ ${#errors[@]} -eq 0 ]
}

self_test() {
  # set -e skips commands negated with ! or inside && lists, so each line fails explicitly
  check_title 'feat(runtime): add journal' && check_title 'fix!: drop x' && ! check_title 'Add stuff' && ! check_title 'feat:missing space' || return 1
  [ "$(printf 'src/a.ts\t10\t5\npnpm-lock.yaml\t900\t900\npkg/generated/x.ts\t50\t0\nb.gen.ts\t3\t3\n' | count_lines)" = 15 ] || return 1
  [ "$(printf 'packages/tui/test/frames/80x24-en.txt\t900\t800\npackages/tui/test/app.test.tsx\t7\t2\nframes/x.ts\t4\t0\n' | count_lines)" = 13 ] || return 1
  [ "$(printf 'items/skill/a/x/SKILL.md\t9000\t0\nsrc/harvest.ts\t5\t1\n' | SIZE_EXEMPT='^items/' count_lines)" = 6 ] || return 1
  [ "$(printf 'items/skill/a/x/SKILL.md\t9000\t0\n' | SIZE_EXEMPT='' count_lines)" = 9000 ] || return 1
  provenance_ok $'feat: x\n\nAgent-Session: abc' && provenance_ok $'docs: y\n\nHuman-Authored: yes' || return 1
  ! provenance_ok 'feat: none' && ! provenance_ok $'feat: both\n\nAgent-Session: a\nHuman-Authored: yes' || return 1
  provenance_ok $'feat: squash\n\nAgent-Session: a\nAgent-Session: b' any && ! provenance_ok 'feat: none' any || return 1
  ! provenance_ok $'feat: squash\n\nAgent-Session: a\nAgent-Session: b' || return 1
  printf 'labeled\tsize-exempt\town\n' | OWNER=own labeled_by_owner size-exempt || return 1
  ! printf 'labeled\tsize-exempt\tagent\n' | OWNER=own labeled_by_owner size-exempt || return 1
  ! printf 'unlabeled\tsize-exempt\town\nlabeled\tsize-exempt-x\town\n' | OWNER=own labeled_by_owner size-exempt || return 1
  ! printf 'labeled\tsize-exempt\t\n' | OWNER='' labeled_by_owner size-exempt || return 1
  printf 'packages/policy/src/a.ts\n' | touches_protected $'packages/exec/*\npackages/policy/*' || return 1
  ! printf 'docs/readme.md\n' | touches_protected $'packages/policy/*' || return 1
  ! printf 'docs/readme.md\n' | touches_protected '' || return 1
  echo "pr-guard self-test: ok"
}

case "${1:-}" in
  check) check ;;
  self-test) self_test ;;
  *) echo "usage: $0 check|self-test" >&2; exit 2 ;;
esac
