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

# $1: a commit's trailers as Git parses them; exactly one provenance trailer
provenance_ok() {
  local a h
  a=$(grep -cE '^Agent-Session: .+' <<<"$1" || true)
  h=$(grep -cE '^Human-Authored: .+' <<<"$1" || true)
  [ $((a + h)) -eq 1 ]
}

# $1: a message; the trailers Git sees, its last paragraph only (strategy#191)
trailers_of() { git interpret-trailers --parse --unfold <<<"$1"; }

# Every commit of $2..$3 in the git dir $1, the whole range: the PR commits API stops at 250
# (x2e-dev/.github#9). $4 non-empty (the owner's size-exempt) lets the commits listed in $IMPORTED,
# moved history whose trailer Git does not see (zoryax#2083), pass with any provenance line. Prints
# one line per bad commit and sets CHECKED; fails when git does.
check_commits() {
  local shas sha t n=0 total
  shas=$(git -C "$1" rev-list "$2..$3") || return 2
  total=$(git -C "$1" rev-list --count "$2..$3") || return 2
  for sha in $shas; do
    n=$((n + 1))
    t=$(git -C "$1" log -1 --format='%(trailers:only,unfold)' "$sha") || return 2
    provenance_ok "$t" && continue
    if [ -n "${4:-}" ] && grep -qx "$sha" <<<"${IMPORTED:-}"; then
      git -C "$1" log -1 --format=%B "$sha" | grep -qE '^(Agent-Session|Human-Authored): .+' && continue
    fi
    echo "commit ${sha:0:7} needs exactly one trailer Git parses, last and alone: 'Agent-Session: <id>' or 'Human-Authored: yes'"
  done
  CHECKED=$n
  [ "$n" -eq "$total" ] || return 2
}

# stdin: event<TAB>label<TAB>actor of a PR's issue events, oldest first; true when label $1's last
# transition is $OWNER adding it: a removal revokes, anyone else's re-add does not count (.github#8)
labeled_by_owner() {
  awk -F'\t' -v l="$1" -v o="$OWNER" '$2 == l && $1 == "labeled" { f = (o != "" && $3 == o) } $2 == l && $1 == "unlabeled" { f = 0 } END { exit !f }'
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
  local errors=() warnings=() title files lines head base_ref pull e
  pull=$(gh api "repos/$REPO/pulls/$PR" --jq '[.head.sha, .base.ref, .title] | @tsv')
  IFS=$'\t' read -r head base_ref title <<<"$pull"
  check_title "$title" || errors+=("PR title is not Conventional Commits: '$title'")

  # Labels count only when the owner's account added them. Caveat: agents that act with the owner's
  # token are indistinguishable from the owner; give agents their own GitHub App identity (infra/README.md).
  local events
  events=$(gh api --paginate "repos/$REPO/issues/$PR/events" --jq '.[] | [.event, .label.name // "", .actor.login // ""] | @tsv')
  owner_labeled() { labeled_by_owner "$1" <<<"$events"; }

  # size-exempt: a one-time move of a whole tree with its history (owner, 2026-11-26, zoryax#2083)
  local exempt=""
  local IMPORTED=""
  if owner_labeled size-exempt; then
    exempt=yes
    # the reviewed list of moved commits, from this script's own ref, never from the PR
    IMPORTED=$(gh api -H 'Accept: application/vnd.github.raw' 'repos/x2e-dev/.github/contents/scripts/pr-guard-imported.txt?ref=main' |
      awk -v r="$REPO" '$1 == r { print $2 }')
  fi

  files=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[] | [.filename, .additions, .deletions] | @tsv')
  lines=$(count_lines <<<"$files")
  if [ -n "$exempt" ]; then warnings+=("size-exempt by @$OWNER: $lines lines, size limits lifted, listed moved commits accepted")
  elif [ "$lines" -gt "$HARD_LIMIT" ]; then errors+=("PR changes $lines lines (> $HARD_LIMIT); split it")
  elif [ "$lines" -gt "$SOFT_LIMIT" ]; then warnings+=("PR changes $lines lines (> $SOFT_LIMIT); explain why in the description"); fi

  # The commit graph only (no trees or blobs), with the token in the environment, not in argv
  local git_dir="${RUNNER_TEMP:-/tmp}/pr-guard-$PR.git" bad
  rm -rf "${git_dir:?}"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)" \
    git clone -q --bare --filter=tree:0 --no-tags --single-branch --branch "$base_ref" "https://github.com/$REPO" "$git_dir"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)" \
    git -C "$git_dir" fetch -q --filter=tree:0 origin "$head"
  bad=$(mktemp)
  if check_commits "$git_dir" "refs/heads/$base_ref" "$head" "$exempt" >"$bad"; then
    while IFS= read -r e; do errors+=("$e"); done <"$bad"
    warnings+=("provenance checked on $CHECKED commits")
  else
    errors+=("could not read every commit of the PR")
  fi
  rm -f "$bad"

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

# A throwaway repository: 251 commits past the PR commits API's 250 (x2e-dev/.github#9), one whose
# trailer Git does not see (strategy#191), and a git failure
commits_self_test() {
  local d m i o
  d=$(mktemp -d)
  git -C "$d" init -q -b main && git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base || return 1
  git -C "$d" tag base
  for i in $(seq 251); do
    if [ $((i % 2)) = 0 ]; then m='Agent-Session: a'; else m='Human-Authored: yes'; fi
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "feat: c$i" -m "$m" || return 1
  done
  o=$(mktemp); check_commits "$d" base main >"$o" && [ ! -s "$o" ] && [ "$CHECKED" = 251 ] || return 1
  git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'feat: late' -m 'Agent-Session: a' -m 'Co-authored-by: b <b@x>' || return 1
  local late; late=$(git -C "$d" rev-parse HEAD)
  check_commits "$d" base main >"$o" && [ "$CHECKED" = 252 ] && [[ $(cat "$o") == "commit ${late:0:7} "* ]] || return 1
  # listed imported history passes only under the owner's size-exempt
  IMPORTED=$late check_commits "$d" base main >"$o" && [ -s "$o" ] || return 1
  IMPORTED=$late check_commits "$d" base main x >"$o" && [ ! -s "$o" ] || return 1
  check_commits "$d" base no-such-ref >/dev/null 2>&1 && return 1
  check_commits "$d/missing" base main >/dev/null 2>&1 && return 1
  rm -f "$o" && rm -rf "${d:?}/.git" && rmdir "$d"
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
  provenance_ok "$(trailers_of $'feat: x\n\nAgent-Session: a\n\nCo-authored-by: b <b@x>')" && return 1
  provenance_ok "$(trailers_of $'feat: x\n\nAgent-Session: a')" || return 1
  # the label's last transition counts (x2e-dev/.github#8)
  printf 'labeled\tsize-exempt\town\nunlabeled\tsize-exempt\town\n' | OWNER=own labeled_by_owner size-exempt && return 1
  printf 'labeled\tsize-exempt\town\nunlabeled\tsize-exempt\town\nlabeled\tsize-exempt\tagent\n' | OWNER=own labeled_by_owner size-exempt && return 1
  printf 'labeled\tsize-exempt\tagent\nunlabeled\tsize-exempt\tagent\nlabeled\tsize-exempt\town\n' | OWNER=own labeled_by_owner size-exempt || return 1
  printf 'labeled\tsize-exempt\town\nunlabeled\towner-approved\town\n' | OWNER=own labeled_by_owner size-exempt || return 1
  commits_self_test || return 1
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
