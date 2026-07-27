#!/usr/bin/env bash
# Execute one bounded, single-agent ZigCSS development pass.
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

PROMPT=''
IFS= read -r -d '' PROMPT <<'EOF' || true
You are the sole implementation agent for the approved ZigCSS autonomous development roadmap.

Hard execution contract:
- Use only gpt-5.6-sol with xhigh reasoning, as selected by the invoking runner. Never delegate, spawn subagents, create child tasks, or fall back to another model.
- Work only in this isolated worktree and preserve every inherited or unrelated change. Never access or modify the user's main checkout.
- Read DEVELOPMENT_PLAN.md completely before changing code. Treat it as the authoritative roadmap, dependency graph, gates, safety policy, and definition of done.
- Read DEVELOPMENT_STATUS.md and run scripts/autodevelop/orient.sh before selecting work. If a coherent interrupted package is dirty, resume it before selecting another.
- Milestone 10 self-contained native stylesheet frontend work is active. Select the earliest dependency-eligible package not marked VERIFIED in DEVELOPMENT_STATUS.md, in this exact order: NATIVE-001 through NATIVE-005; NSASS-010 through NSASS-012; NLESS-010 through NLESS-012; NSTYLUS-010 through NSTYLUS-012; then NATIVE-006 through NATIVE-009. When an umbrella package is IN_PROGRESS, resume its smallest status-designated next eligible slice instead of jumping to a later package. A pending external BENCH-007 runner must not block eligible native frontend correctness work.
- Execute at most one smallest dependency-ordered work package in this pass: reproduce or measure, add/strengthen tests, implement the smallest correct change, run proportionate gates, search sibling surfaces, update the ledger, and commit intentional green checkpoints.
- Prioritize security, parser correctness, semantic preservation, determinism, and regression evidence. Do not weaken tests or quality gates.
- Do not push from this model pass. The outer Bash supervisor alone may atomically non-force push the independently verified clean checkpoint to the approved origin recovery branch and origin/main. Do not publish, deploy, create a PR/tag/release, send messages, spend money, use secrets, or modify any other external system.
- Do not fetch, pull, rebase, merge, or switch branches. Stage only explicit package-owned paths; never use git add -A.
- Make safe reversible engineering decisions without asking. Report BLOCKED only for a true authority/external-state/irreversible-decision blocker after exhausting in-scope alternatives. Give each blocker a lowercase kebab-case stable code and reuse that code while the underlying condition is unchanged, even if the explanation changes.
- Leave the worktree clean after PROGRESS or COMPLETE. A local commit is required for progress. Do not sleep or wait for rate limits; the outer Bash supervisor owns continuation.

As the final line of the response, emit exactly one result marker:
ZIGCSS-AUTODEVELOP-STATUS: PROGRESS <short summary>
ZIGCSS-AUTODEVELOP-STATUS: BLOCKED <stable-code>: <reason>
ZIGCSS-AUTODEVELOP-STATUS: COMPLETE
EOF

if [ "${1:-}" = "--print-prompt" ]; then
  printf '%s\n' "$PROMPT"
  exit 0
fi
if [ "$#" -ne 0 ]; then
  autodevelop_die "usage: run-pass.sh [--print-prompt]"
  exit 2
fi

autodevelop_require_repository || exit 1
[ -n "$AUTODEVELOP_CODEX_BIN" ] && [ -x "$AUTODEVELOP_CODEX_BIN" ] || {
  autodevelop_die "Codex CLI is unavailable"
  exit 1
}

cd "$AUTODEVELOP_ROOT" || exit 1
GIT_DIR="$(git rev-parse --absolute-git-dir)" || exit 1
GIT_COMMON_RAW="$(git rev-parse --git-common-dir)" || exit 1
GIT_COMMON_DIR="$(CDPATH= cd -- "$GIT_COMMON_RAW" && pwd -P)" || exit 1
case "$GIT_DIR$GIT_COMMON_DIR" in
  *\"*) autodevelop_die "Git metadata paths cannot be encoded safely for Codex"; exit 1 ;;
esac

BEFORE_HEAD="$(git rev-parse HEAD)" || exit 1
BEFORE_STATUS="$(autodevelop_git_status)"
PASS_ID="$(date +%Y%m%d-%H%M%S)"
OUTPUT="$AUTODEVELOP_LOG_DIR/pass-$PASS_ID.log"
FINAL_MESSAGE="$AUTODEVELOP_LOG_DIR/pass-$PASS_ID.final.txt"
ln -sfn "$OUTPUT" "$AUTODEVELOP_LOG_DIR/pass-latest.log"
ln -sfn "$FINAL_MESSAGE" "$AUTODEVELOP_LOG_DIR/pass-latest.final.txt"
rm -f "$FINAL_MESSAGE"

export ZIG_GLOBAL_CACHE_DIR="$AUTODEVELOP_CACHE_DIR/zig-global"
export npm_config_cache="$AUTODEVELOP_CACHE_DIR/npm"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$npm_config_cache"

autodevelop_log INFO "pass start head=${BEFORE_HEAD%????????????????????????????????} model=$AUTODEVELOP_MODEL effort=$AUTODEVELOP_REASONING timeout=${AUTODEVELOP_PASS_TIMEOUT_SECS}s output=$OUTPUT"

RAW_RC=0
autodevelop_run_with_timeout "$AUTODEVELOP_PASS_TIMEOUT_SECS" \
  "$AUTODEVELOP_CODEX_BIN" exec \
  --ephemeral \
  --cd "$AUTODEVELOP_ROOT" \
  --sandbox workspace-write \
  --model "$AUTODEVELOP_MODEL" \
  --output-last-message "$FINAL_MESSAGE" \
  -c "model_reasoning_effort=\"$AUTODEVELOP_REASONING\"" \
  -c 'approval_policy="never"' \
  -c 'sandbox_workspace_write.network_access=true' \
  -c "sandbox_workspace_write.writable_roots=[\"$GIT_DIR\",\"$GIT_COMMON_DIR\"]" \
  "$PROMPT" </dev/null >"$OUTPUT" 2>&1 || RAW_RC=$?

[ -f "$FINAL_MESSAGE" ] || : > "$FINAL_MESSAGE"
CLASS="$(autodevelop_classify_pass "$RAW_RC" "$OUTPUT" "$FINAL_MESSAGE")"
STATUS="$(autodevelop_extract_status "$FINAL_MESSAGE")"
BLOCKER_CODE="$(autodevelop_extract_blocker_code "$FINAL_MESSAGE")"
REASON="$(autodevelop_extract_reason "$FINAL_MESSAGE")"
AFTER_HEAD="$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')"
AFTER_STATUS="$(autodevelop_git_status)"

if { [ "$CLASS" = PROGRESS ] || [ "$CLASS" = COMPLETE ]; } && [ -n "$AFTER_STATUS" ]; then
  CLASS=ERROR
  STATUS=DIRTY
  REASON="agent reported $STATUS but left tracked or untracked work"
fi
if [ "$CLASS" = PROGRESS ] && [ "$BEFORE_HEAD" = "$AFTER_HEAD" ]; then
  CLASS=ERROR
  STATUS=NO_COMMIT
  REASON="agent reported progress without an intentional local commit"
fi

if [ -n "$AFTER_STATUS" ]; then
  autodevelop_record_resume_wip
else
  rm -f "$AUTODEVELOP_RESUME_WIP_FILE"
fi

LAST_RUN_TMP="$AUTODEVELOP_STATE_DIR/.last-run.$$"
{
  printf 'PASS_ID=%s\n' "$PASS_ID"
  printf 'RAW_RC=%s\n' "$RAW_RC"
  printf 'CLASS=%s\n' "$CLASS"
  printf 'STATUS=%s\n' "${STATUS:-NONE}"
  printf 'BLOCKER_CODE=%s\n' "${BLOCKER_CODE:-NONE}"
  printf 'BEFORE_HEAD=%s\n' "$BEFORE_HEAD"
  printf 'AFTER_HEAD=%s\n' "$AFTER_HEAD"
  printf 'OUTPUT=%s\n' "$OUTPUT"
  printf 'FINAL_MESSAGE=%s\n' "$FINAL_MESSAGE"
} > "$LAST_RUN_TMP"
mv "$LAST_RUN_TMP" "$AUTODEVELOP_STATE_DIR/last-run.env"
printf '%s' "$REASON" > "$AUTODEVELOP_STATE_DIR/last-run.reason"

autodevelop_log INFO "pass end rc=$RAW_RC class=$CLASS status=${STATUS:-NONE} head=${AFTER_HEAD%????????????????????????????????}"

case "$CLASS" in
  PROGRESS|BLOCKED|COMPLETE) exit 0 ;;
  *) if [ "$RAW_RC" -ne 0 ]; then exit "$RAW_RC"; else exit 1; fi ;;
esac
