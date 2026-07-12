#!/usr/bin/env bash
# Operator control surface for the ZigCSS autonomous development loop.
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

running_pid() {
  local pid
  pid="$(cat "$AUTODEVELOP_PID_FILE" 2>/dev/null || printf '0')"
  if [ "$pid" -gt 1 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
  fi
}

require_not_running() {
  local pid
  pid="$(running_pid)"
  if [ -n "$pid" ]; then
    autodevelop_die "loop already running (pid $pid)"
    return 1
  fi
}

require_startable_tree() {
  local expected current
  autodevelop_require_repository || return 1
  if autodevelop_git_clean; then
    rm -f "$AUTODEVELOP_RESUME_WIP_FILE"
  else
    expected="$(cat "$AUTODEVELOP_RESUME_WIP_FILE" 2>/dev/null || true)"
    current="$(autodevelop_dirty_fingerprint)"
    if [ -z "$expected" ] || [ "$expected" != "$current" ]; then
      autodevelop_die "initial start requires a clean tree or the exact runner-recorded interrupted WIP"
      return 1
    fi
  fi
}

doctor() {
  local failures=0
  printf 'ZigCSS autodevelop doctor\n'
  printf 'root: %s\n' "$AUTODEVELOP_ROOT"
  printf 'state: %s\n' "$AUTODEVELOP_HOME"
  printf 'branch: %s\n' "$(git -C "$AUTODEVELOP_ROOT" branch --show-current 2>/dev/null || printf 'unavailable')"
  printf 'model: %s\n' "$AUTODEVELOP_MODEL"
  printf 'reasoning: %s\n' "$AUTODEVELOP_REASONING"
  autodevelop_require_repository || failures=$((failures + 1))
  if [ -z "$AUTODEVELOP_CODEX_BIN" ] || [ ! -x "$AUTODEVELOP_CODEX_BIN" ]; then
    printf 'codex: unavailable\n' >&2
    failures=$((failures + 1))
  else
    printf 'codex: %s (%s)\n' "$AUTODEVELOP_CODEX_BIN" "$("$AUTODEVELOP_CODEX_BIN" --version 2>/dev/null | head -1)"
    if "$AUTODEVELOP_CODEX_BIN" login status >/dev/null 2>&1; then
      printf 'auth: ready\n'
    else
      printf 'auth: not ready (run codex login)\n' >&2
      failures=$((failures + 1))
    fi
  fi
  if git -C "$AUTODEVELOP_ROOT" check-ignore -q .autodevelop/probe; then
    printf 'state ignore: verified\n'
  else
    printf 'state ignore: .autodevelop is not ignored\n' >&2
    failures=$((failures + 1))
  fi
  PUSH_CHECK="$(bash "$HERE/push-checkpoint.sh" --check 2>&1)" || {
    printf 'push: unavailable (%s)\n' "$PUSH_CHECK" >&2
    failures=$((failures + 1))
    PUSH_CHECK=''
  }
  if [ -n "$PUSH_CHECK" ]; then printf '%s\n' "$PUSH_CHECK"; fi
  printf 'worktree: %s\n' "$(if autodevelop_git_clean; then printf 'clean'; else printf 'dirty'; fi)"
  if [ "$failures" -ne 0 ]; then return 1; fi
}

usage() {
  printf '%s\n' \
    'usage: scripts/autodevelop/ctl.sh doctor|test|run|start|stop|pause|resume|status|logs|orient' \
    '  doctor  verify repo, fixed model/effort, CLI auth, and ignored state' \
    '  test    run one bounded pass in the foreground' \
    '  run     run the continuous supervisor in the foreground' \
    '  start   run the supervisor in the background for this login' \
    '  stop    stop after the current pass (or immediately while idle)' \
    '  pause   pause after the current pass' \
    '  resume  continue a paused loop' \
    '  status  show runner, Git, and last-pass state' \
    '  logs    follow the orchestrator log' \
    '  orient  run the read-only repository orientation'
}

COMMAND="${1:-status}"
shift 2>/dev/null || true

case "$COMMAND" in
  doctor)
    doctor
    ;;
  test)
    require_not_running || exit 1
    require_startable_tree || exit 1
    bash "$HERE/run-pass.sh"
    ;;
  run)
    require_not_running || exit 1
    require_startable_tree || exit 1
    rm -f "$AUTODEVELOP_STOP_FILE"
    exec bash "$HERE/loop.sh"
    ;;
  start)
    require_not_running || exit 1
    require_startable_tree || exit 1
    doctor >/dev/null || {
      autodevelop_die "doctor failed; run ctl.sh doctor for details"
      exit 1
    }
    rm -f "$AUTODEVELOP_STOP_FILE" "$AUTODEVELOP_COMPLETE_FILE"
    if [ "$(uname -s)" = Darwin ] && command -v launchctl >/dev/null 2>&1; then
      launchctl remove "$AUTODEVELOP_LAUNCH_LABEL" >/dev/null 2>&1 || true
      LAUNCH_ENV=(/usr/bin/env "HOME=$HOME" "PATH=$PATH")
      for variable in TMPDIR LANG LC_ALL SHELL USER LOGNAME MACOSX_DEPLOYMENT_TARGET; do
        value="${!variable:-}"
        if [ -n "$value" ]; then LAUNCH_ENV+=("$variable=$value"); fi
      done
      launchctl submit \
        -l "$AUTODEVELOP_LAUNCH_LABEL" \
        -o "$AUTODEVELOP_LOG_DIR/launch.log" \
        -e "$AUTODEVELOP_LOG_DIR/launch.log" \
        -- "${LAUNCH_ENV[@]}" /bin/bash "$HERE/loop.sh" || {
          autodevelop_die "launchctl submit failed"
          exit 1
        }
      STARTED_BY="transient launchd job $AUTODEVELOP_LAUNCH_LABEL"
    else
      nohup bash "$HERE/loop.sh" >> "$AUTODEVELOP_LOG_DIR/launch.log" 2>&1 </dev/null &
      STARTED_BY="launcher pid $!"
    fi
    attempts=0
    LIVE_PID=''
    while [ "$attempts" -lt 50 ]; do
      LIVE_PID="$(running_pid)"
      if [ -n "$LIVE_PID" ]; then break; fi
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if [ -z "$LIVE_PID" ]; then
      autodevelop_die "runner failed to start; inspect $AUTODEVELOP_LOG_DIR/launch.log"
      exit 1
    fi
    printf 'started ZigCSS autodevelop pid %s (%s)\n' "$LIVE_PID" "$STARTED_BY"
    printf 'status: %s status\n' "$HERE/ctl.sh"
    printf 'logs:   %s logs\n' "$HERE/ctl.sh"
    ;;
  stop)
    touch "$AUTODEVELOP_STOP_FILE"
    rm -f "$AUTODEVELOP_PAUSE_FILE"
    printf 'stop requested; the active pass, if any, will finish first\n'
    ;;
  pause)
    touch "$AUTODEVELOP_PAUSE_FILE"
    printf 'pause requested; the active pass, if any, will finish first\n'
    ;;
  resume)
    rm -f "$AUTODEVELOP_PAUSE_FILE"
    printf 'resumed\n'
    ;;
  status)
    PID="$(running_pid)"
    if [ -n "$PID" ]; then printf 'runner: active pid %s\n' "$PID"; else printf 'runner: stopped\n'; fi
    if [ -f "$AUTODEVELOP_PAUSE_FILE" ]; then printf 'control: paused\n'; fi
    if [ -f "$AUTODEVELOP_STOP_FILE" ]; then printf 'control: stopping/stopped\n'; fi
    if [ -f "$AUTODEVELOP_COMPLETE_FILE" ]; then printf 'control: complete\n'; fi
    printf 'branch: %s\n' "$(git -C "$AUTODEVELOP_ROOT" branch --show-current 2>/dev/null || printf 'unavailable')"
    printf 'worktree:\n'
    STATUS="$(autodevelop_git_status)"
    if [ -n "$STATUS" ]; then printf '%s\n' "$STATUS"; else printf '(clean)\n'; fi
    if [ -f "$AUTODEVELOP_STATE_DIR/status.txt" ]; then
      printf '\nloop status:\n'
      cat "$AUTODEVELOP_STATE_DIR/status.txt"
    fi
    if [ -f "$AUTODEVELOP_STATE_DIR/last-run.env" ]; then
      printf '\nlast pass:\n'
      cat "$AUTODEVELOP_STATE_DIR/last-run.env"
      REASON="$(cat "$AUTODEVELOP_STATE_DIR/last-run.reason" 2>/dev/null || true)"
      if [ -n "$REASON" ]; then printf 'REASON=%s\n' "$REASON"; fi
    fi
    if [ -f "$AUTODEVELOP_STATE_DIR/last-pushed-head" ]; then
      printf '\nlast pushed:\n'
      printf 'HEAD=%s\n' "$(cat "$AUTODEVELOP_STATE_DIR/last-pushed-head")"
      printf 'BRANCH=%s\n' "$(cat "$AUTODEVELOP_STATE_DIR/last-pushed-branch" 2>/dev/null || printf 'unknown')"
    fi
    ;;
  logs)
    touch "$AUTODEVELOP_ORCHESTRATOR_LOG"
    tail -f "$AUTODEVELOP_ORCHESTRATOR_LOG"
    ;;
  orient)
    exec bash "$HERE/orient.sh"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
