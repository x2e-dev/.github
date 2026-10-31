#!/usr/bin/env bash
# PR guard for x2e-dev. Enforces AGENTS.md rules 2-4, 7 and 9 in CI while the org is on GitHub Free
# and the repositories are private (no rulesets, required reviews or merge queue until M4).
# Usage: pr-guard.sh check      (in CI; needs GH_TOKEN, REPO, PR, OWNER, PROTECTED)
#        pr-guard.sh self-test  (local)
set -euo pipefail

export GENERATED_RE='(^|/)(pnpm-lock\.yaml|package-lock\.json|Cargo\.lock|bun\.lockb?)$|(^|/)generated/|\.gen\.'
SOFT_LIMIT=400
HARD_LIMIT=1000

check_title() { [[ $1 =~ ^(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?:\ .+ ]]; }

# stdin: filename<TAB>additions<TAB>deletions; prints changed lines outside generated files
count_lines() { awk -F'\t' '$1 !~ ENVIRON["GENERATED_RE"] { n += $2 + $3 } END { print n + 0 }'; }

# exactly one provenance trailer per commit message
provenance_ok() {
  local a h
  a=$(grep -cE '^Agent-Session: .+' <<<"$1" || true)
  h=$(grep -cE '^Human-Authored: .+' <<<"$1" || true)
  [ $((a + h)) -eq 1 ]
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

  files=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[] | [.filename, .additions, .deletions] | @tsv')
  lines=$(count_lines <<<"$files")
  if [ "$lines" -gt "$HARD_LIMIT" ]; then errors+=("PR changes $lines lines (> $HARD_LIMIT); split it")
  elif [ "$lines" -gt "$SOFT_LIMIT" ]; then warnings+=("PR changes $lines lines (> $SOFT_LIMIT); explain why in the description"); fi

  while read -r sha msg64; do
    provenance_ok "$(base64 -d <<<"$msg64")" || errors+=("commit ${sha:0:7} needs exactly one trailer: 'Agent-Session: <id>' or 'Human-Authored: yes'")
  done < <(gh api --paginate "repos/$REPO/pulls/$PR/commits" --jq '.[] | "\(.sha) \(.commit.message | @base64)"')

  # Labels count only when the owner's account added them. Caveat: agents that act with the owner's
  # token are indistinguishable from the owner; give agents their own GitHub App identity (infra/README.md).
  owner_labeled() {
    gh api --paginate "repos/$REPO/issues/$PR/events" \
      --jq ".[] | select(.event == \"labeled\" and .label.name == \"$1\" and .actor.login == \"$OWNER\") | .id" | grep -q .
  }
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
  check_title 'feat(runtime): add journal' && check_title 'fix!: drop x' && ! check_title 'Add stuff' && ! check_title 'feat:missing space'
  [ "$(printf 'src/a.ts\t10\t5\npnpm-lock.yaml\t900\t900\npkg/generated/x.ts\t50\t0\nb.gen.ts\t3\t3\n' | count_lines)" = 15 ]
  provenance_ok $'feat: x\n\nAgent-Session: abc' && provenance_ok $'docs: y\n\nHuman-Authored: yes'
  ! provenance_ok 'feat: none' && ! provenance_ok $'feat: both\n\nAgent-Session: a\nHuman-Authored: yes'
  printf 'packages/policy/src/a.ts\n' | touches_protected $'packages/exec/*\npackages/policy/*'
  ! printf 'docs/readme.md\n' | touches_protected $'packages/policy/*'
  ! printf 'docs/readme.md\n' | touches_protected ''
  echo "pr-guard self-test: ok"
}

case "${1:-}" in
  check) check ;;
  self-test) self_test ;;
  *) echo "usage: $0 check|self-test" >&2; exit 2 ;;
esac
