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
  REASON="$(cat "$AUTODEVELOP_STATE_DIR/last-run.reason" 2>/dev/null || true)"

  case "$CLASS" in
    PROGRESS)
      autodevelop_state_set consecutive-errors 0
      autodevelop_state_set blocked-count 0
      autodevelop_state_set blocked-fingerprint ''
      write_loop_status PROGRESS "checkpoint complete; continuing"
      autodevelop_sleep_interruptible "$AUTODEVELOP_INTER_PASS_SECS" || true
      ;;
    COMPLETE)
      touch "$AUTODEVELOP_COMPLETE_FILE"
      write_loop_status COMPLETE "roadmap completion reported"
      autodevelop_notify_local "ZigCSS autodevelop complete" "The runner reported complete; review DEVELOPMENT_STATUS.md and local commits."
      break
      ;;
    BLOCKED)
      FINGERPRINT="$(printf '%s' "$REASON" | shasum -a 256 | awk '{print $1}')"
      PRIOR="$(autodevelop_state_get blocked-fingerprint '')"
      if [ "$FINGERPRINT" = "$PRIOR" ]; then
        BLOCKED_COUNT="$(autodevelop_state_increment blocked-count)"
      else
        autodevelop_state_set blocked-fingerprint "$FINGERPRINT"
        autodevelop_state_set blocked-count 1
        BLOCKED_COUNT=1
      fi
      write_loop_status BLOCKED "attempt $BLOCKED_COUNT/3: $REASON"
      autodevelop_log WARN "blocked attempt $BLOCKED_COUNT/3: ${REASON:-unspecified}"
      if [ "$BLOCKED_COUNT" -ge 3 ]; then
        touch "$AUTODEVELOP_PAUSE_FILE"
        autodevelop_notify_local "ZigCSS autodevelop blocked" "Same blocker repeated three times: ${REASON:-see logs}. Runner paused."
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
