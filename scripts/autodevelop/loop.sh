#!/usr/bin/env bash
# Serialized outer supervisor: one Codex pass, classify, back off, repeat.
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

LOCK_DIR="$AUTODEVELOP_STATE_DIR/loop.lock"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid"
    return
  fi
  local owner
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || printf '0')"
  if [ "$owner" -gt 1 ] 2>/dev/null && kill -0 "$owner" 2>/dev/null; then
    autodevelop_die "another loop is active (pid $owner)"
    exit 1
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || exit 1
  printf '%s' "$$" > "$LOCK_DIR/pid"
}

write_loop_status() {
  local phase="$1"
  local detail="${2:-}"
  local temporary="$AUTODEVELOP_STATE_DIR/.status.$$"
  {
    printf 'ZigCSS autodevelop — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'phase=%s\n' "$phase"
    printf 'pid=%s\n' "$$"
    printf 'model=%s\n' "$AUTODEVELOP_MODEL"
    printf 'reasoning=%s\n' "$AUTODEVELOP_REASONING"
    printf 'head=%s\n' "$(git -C "$AUTODEVELOP_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unavailable')"
    printf 'dirty=%s\n' "$(if autodevelop_git_clean; then printf 'no'; else printf 'yes'; fi)"
    if [ -n "$detail" ]; then printf 'detail=%s\n' "$detail"; fi
  } > "$temporary"
  mv "$temporary" "$AUTODEVELOP_STATE_DIR/status.txt"
}

cleanup() {
  if ! autodevelop_git_clean; then autodevelop_record_resume_wip; fi
  rm -f "$AUTODEVELOP_PID_FILE"
  rm -rf "$LOCK_DIR"
}

push_green_checkpoint() {
  if bash "$HERE/push-checkpoint.sh" "$@"; then return 0; fi
  write_loop_status PUSH_FAILED "green checkpoint remains local or recovery-backed; automatic push failed"
  autodevelop_log ERROR "automatic push failed; supervisor stopped without rewriting remote history"
  autodevelop_notify_local "ZigCSS automatic push failed" "The clean checkpoint remains local or recovery-backed; inspect the orchestrator log before restarting."
  return 1
}

trap 'touch "$AUTODEVELOP_STOP_FILE"' TERM INT HUP
trap cleanup EXIT

autodevelop_require_repository || exit 1
acquire_lock
printf '%s' "$$" > "$AUTODEVELOP_PID_FILE"
rm -f "$AUTODEVELOP_COMPLETE_FILE"
autodevelop_log INFO "loop start root=$AUTODEVELOP_ROOT model=$AUTODEVELOP_MODEL effort=$AUTODEVELOP_REASONING"
write_loop_status STARTING

while :; do
  if [ -f "$AUTODEVELOP_STOP_FILE" ]; then
    write_loop_status STOPPED "operator stop requested"
    autodevelop_log INFO "loop stopped by operator request"
    break
  fi

  if [ -f "$AUTODEVELOP_PAUSE_FILE" ]; then
    write_loop_status PAUSED "remove PAUSE with ctl.sh resume"
    sleep "$AUTODEVELOP_IDLE_POLL_SECS"
    continue
  fi

  write_loop_status RUNNING "executing one bounded pass"
  PASS_RC=0
  bash "$HERE/run-pass.sh" || PASS_RC=$?
  CLASS="$(grep '^CLASS=' "$AUTODEVELOP_STATE_DIR/last-run.env" 2>/dev/null | cut -d= -f2)"
  OUTPUT="$(grep '^OUTPUT=' "$AUTODEVELOP_STATE_DIR/last-run.env" 2>/dev/null | cut -d= -f2-)"
  BLOCKER_CODE="$(grep '^BLOCKER_CODE=' "$AUTODEVELOP_STATE_DIR/last-run.env" 2>/dev/null | cut -d= -f2-)"
  GAP_PACKAGE="$(grep '^GAP_PACKAGE=' "$AUTODEVELOP_STATE_DIR/last-run.env" 2>/dev/null | cut -d= -f2-)"
  GAP_FAMILY="$(grep '^GAP_FAMILY=' "$AUTODEVELOP_STATE_DIR/last-run.env" 2>/dev/null | cut -d= -f2-)"
  GAP_RESULT="$(grep '^GAP_RESULT=' "$AUTODEVELOP_STATE_DIR/last-run.env" 2>/dev/null | cut -d= -f2-)"
  REASON="$(cat "$AUTODEVELOP_STATE_DIR/last-run.reason" 2>/dev/null || true)"

  case "$CLASS" in
    PROGRESS)
      push_green_checkpoint --recovery-only || break
      if ! FAMILY_COUNT="$(autodevelop_record_gap_progress "$GAP_FAMILY" "$GAP_RESULT")"; then
        touch "$AUTODEVELOP_PAUSE_FILE"
        write_loop_status ERROR "invalid release-gap convergence state; runner paused"
        autodevelop_log ERROR "release-gap convergence state rejected after recovery push"
        continue
      fi
      MAIN_BATCH_STATE="$(autodevelop_main_batch_advance)"
      MAIN_BATCH_DECISION="${MAIN_BATCH_STATE%% *}"
      MAIN_BATCH_COUNT="${MAIN_BATCH_STATE#* }"
      if autodevelop_should_integrate_main \
        "$MAIN_BATCH_DECISION" "$GAP_PACKAGE" "$GAP_FAMILY" "$GAP_RESULT"; then
        push_green_checkpoint || break
        autodevelop_state_set main-batch-count 0
        PUSH_DETAIL="checkpoint backed up and integrated to main"
      else
        PUSH_DETAIL="checkpoint backed up to recovery; main batch $MAIN_BATCH_COUNT/$AUTODEVELOP_MAIN_BATCH_PASSES"
      fi
      autodevelop_state_set consecutive-errors 0
      autodevelop_state_set blocked-count 0
      autodevelop_state_set blocked-code ''
      if [ -f "$AUTODEVELOP_STATE_DIR/convergence-required" ]; then
        write_loop_status CONVERGENCE "${PUSH_DETAIL}; next pass must close $GAP_FAMILY after $FAMILY_COUNT passes"
      else
        write_loop_status PROGRESS "${PUSH_DETAIL}; release-gap family $GAP_FAMILY is $GAP_RESULT"
      fi
      autodevelop_sleep_interruptible "$AUTODEVELOP_INTER_PASS_SECS" || true
      ;;
    COMPLETE)
      push_green_checkpoint || break
      autodevelop_state_set main-batch-count 0
      touch "$AUTODEVELOP_COMPLETE_FILE"
      write_loop_status COMPLETE "roadmap completion reported; final checkpoint atomically pushed to recovery and main"
      autodevelop_notify_local "ZigCSS autodevelop complete" "The runner reported complete; review DEVELOPMENT_STATUS.md and local commits."
      break
      ;;
    BLOCKED)
      if ! BLOCKED_COUNT="$(autodevelop_record_blocker "$BLOCKER_CODE")"; then
        touch "$AUTODEVELOP_PAUSE_FILE"
        write_loop_status ERROR "invalid stable blocker code; runner paused"
        autodevelop_log ERROR "BLOCKED result lacked a valid stable blocker code"
        autodevelop_notify_local "ZigCSS autodevelop paused" "A BLOCKED result lacked a valid stable blocker code; inspect the latest pass."
        continue
      fi
      write_loop_status BLOCKED "attempt $BLOCKED_COUNT/3 [$BLOCKER_CODE]: $REASON"
      autodevelop_log WARN "blocked attempt $BLOCKED_COUNT/3 code=$BLOCKER_CODE: ${REASON:-unspecified}"
      if [ "$BLOCKED_COUNT" -ge 3 ]; then
        touch "$AUTODEVELOP_PAUSE_FILE"
        autodevelop_notify_local "ZigCSS autodevelop blocked" "Blocker $BLOCKER_CODE repeated three times: ${REASON:-see logs}. Runner paused."
      else
        autodevelop_sleep_interruptible "$AUTODEVELOP_BLOCKED_RECHECK_SECS" || true
      fi
      ;;
    RATE_LIMIT)
      DELAY="$(autodevelop_rate_limit_delay "$OUTPUT")"
      write_loop_status RATE_LIMIT "retry in ${DELAY}s"
      autodevelop_log INFO "rate limit; retry in ${DELAY}s"
      autodevelop_sleep_interruptible "$DELAY" || true
      ;;
    AUTH)
      touch "$AUTODEVELOP_PAUSE_FILE"
      write_loop_status AUTH "Codex login required"
      autodevelop_notify_local "ZigCSS Codex login required" "Run codex login, then scripts/autodevelop/ctl.sh resume."
      ;;
    TIMEOUT|ERROR|*)
      ERROR_COUNT="$(autodevelop_state_increment consecutive-errors)"
      write_loop_status ERROR "class=${CLASS:-MISSING} rc=$PASS_RC attempt=$ERROR_COUNT/5"
      autodevelop_log WARN "pass failure class=${CLASS:-MISSING} rc=$PASS_RC attempt=$ERROR_COUNT/5 output=${OUTPUT:-unknown}"
      if [ "$ERROR_COUNT" -ge 5 ]; then
        touch "$AUTODEVELOP_PAUSE_FILE"
        autodevelop_notify_local "ZigCSS autodevelop paused" "Five consecutive pass failures; inspect ${OUTPUT:-the logs}."
      else
        autodevelop_sleep_interruptible "$AUTODEVELOP_ERROR_BACKOFF_SECS" || true
      fi
      ;;
  esac
done
