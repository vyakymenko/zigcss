#!/usr/bin/env bash
set -euo pipefail

# Read-only orientation for the ZigCSS autonomous development loop.
# Canonical procedure: docs/operations/codex-loop-protocol.md

export GIT_OPTIONAL_LOCKS=0

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "zigcss autodevelop: not inside a Git worktree" >&2
  exit 1
}

PLAN="$ROOT/DEVELOPMENT_PLAN.md"
STATUS="$ROOT/DEVELOPMENT_STATUS.md"

for required in "$PLAN" "$STATUS"; do
  if [[ ! -f "$required" ]]; then
    echo "zigcss autodevelop: missing required file: $required" >&2
    exit 1
  fi
done

cd "$ROOT"

section() {
  printf '\n## %s\n' "$1"
}

ledger_section() {
  local heading="$1"
  awk -v wanted="## $heading" '
    $0 == wanted { printing = 1; next }
    printing && /^## / { exit }
    printing { print }
  ' "$STATUS" | sed '/^[[:space:]]*$/d'
}

tool_version() {
  local tool="$1"
  shift
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%-8s %s\n' "$tool" "$("$tool" "$@" 2>/dev/null | head -n 1)"
  else
    printf '%-8s %s\n' "$tool" '(not on PATH)'
  fi
}

zig_version() {
  if command -v zig >/dev/null 2>&1; then
    printf '%-8s %s (%s)\n' zig "$(zig version)" "$(command -v zig)"
    return
  fi

  local candidate
  for candidate in "$HOME"/.local/share/zig/zig-*/zig; do
    if [[ -x "$candidate" ]]; then
      printf '%-8s %s (%s)\n' zig "$($candidate version)" "$candidate"
      return
    fi
  done

  printf '%-8s %s\n' zig '(not found)'
}

BRANCH="$(git branch --show-current)"
BASE="$(sed -n 's/^- Base commit: `\([0-9a-f][0-9a-f]*\)`.*/\1/p' "$STATUS" | head -n 1)"
MODEL="$(sed -n 's/^- Verified execution model: //p' "$STATUS" | head -n 1)"

printf 'ZigCSS autonomous development orientation\n'
printf 'repo: %s\n' "$ROOT"
printf 'protocol: docs/operations/codex-loop-protocol.md\n'
printf 'roadmap: DEVELOPMENT_PLAN.md\n'
printf 'ledger: DEVELOPMENT_STATUS.md\n'

section 'branch and working tree'
printf 'branch: %s\n' "$BRANCH"
if [[ "$BRANCH" != vale/* ]]; then
  printf 'WARNING: branch does not use the approved vale/ prefix.\n'
fi
WORKTREE_STATUS="$(git status --short)"
if [[ -n "$WORKTREE_STATUS" ]]; then
  printf '%s\n' "$WORKTREE_STATUS"
  printf 'WARNING: finish or preserve the current package before selecting another.\n'
else
  printf '(clean)\n'
fi

section 'execution contract recorded by the ledger'
printf '%s\n' "$MODEL"
printf 'Runtime model selection is app state and must be checked by the active Codex session.\n'

section 'current ledger work'
ledger_section 'Current work'

section 'active blockers'
ledger_section 'Active blockers'

section 'last full validation'
ledger_section 'Last full validation'

section 'recent checkpoints'
git log --oneline -12

section 'recovery delta from the recorded base'
if [[ -n "$BASE" ]] && git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  printf 'base: %s\n' "$BASE"
  DELTA="$(git diff --shortstat "$BASE"..HEAD)"
  if [[ -n "$DELTA" ]]; then
    printf '%s\n' "$DELTA"
    git diff --dirstat=files,10,cumulative "$BASE"..HEAD
  else
    printf '(no committed delta)\n'
  fi
else
  printf 'WARNING: recorded base commit is missing or unreadable.\n'
fi

section 'durable files'
printf 'DEVELOPMENT_PLAN.md   commit %s   sha %s\n' \
  "$(git log -1 --format=%h -- DEVELOPMENT_PLAN.md)" \
  "$(git hash-object DEVELOPMENT_PLAN.md)"
printf 'DEVELOPMENT_STATUS.md commit %s   sha %s\n' \
  "$(git log -1 --format=%h -- DEVELOPMENT_STATUS.md)" \
  "$(git hash-object DEVELOPMENT_STATUS.md)"

section 'local toolchain visibility'
zig_version
tool_version node --version
tool_version npm --version
tool_version docker --version

printf '\nOriented. Read the roadmap section for the current package, verify dependencies,\n'
printf 'then execute one test-first package and update the ledger before checkpointing.\n'
