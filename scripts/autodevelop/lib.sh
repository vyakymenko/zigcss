#!/usr/bin/env bash
# Shared primitives for the single-lane ZigCSS autonomous development runner.
# Keep this compatible with the macOS system Bash 3.2.

AUTODEVELOP_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AUTODEVELOP_ROOT="$(CDPATH= cd -- "$AUTODEVELOP_SCRIPT_DIR/../.." && pwd -P)"
AUTODEVELOP_TEST_MODE="${ZIGCSS_AUTODEVELOP_TEST_MODE:-0}"
if [ -n "${ZIGCSS_AUTODEVELOP_STATE_DIR:-}" ] && [ "$AUTODEVELOP_TEST_MODE" != 1 ]; then
  printf 'zigcss autodevelop: external state override is test-only\n' >&2
  exit 1
fi
AUTODEVELOP_HOME="${ZIGCSS_AUTODEVELOP_STATE_DIR:-$AUTODEVELOP_ROOT/.autodevelop}"
AUTODEVELOP_LOG_DIR="$AUTODEVELOP_HOME/logs"
AUTODEVELOP_STATE_DIR="$AUTODEVELOP_HOME/state"
AUTODEVELOP_CACHE_DIR="$AUTODEVELOP_HOME/cache"
AUTODEVELOP_ORCHESTRATOR_LOG="$AUTODEVELOP_LOG_DIR/orchestrator.log"
AUTODEVELOP_PID_FILE="$AUTODEVELOP_STATE_DIR/loop.pid"
AUTODEVELOP_PAUSE_FILE="$AUTODEVELOP_HOME/PAUSE"
AUTODEVELOP_STOP_FILE="$AUTODEVELOP_HOME/STOP"
AUTODEVELOP_COMPLETE_FILE="$AUTODEVELOP_HOME/COMPLETE"
AUTODEVELOP_RESUME_WIP_FILE="$AUTODEVELOP_STATE_DIR/resume-wip"

AUTODEVELOP_MODEL="gpt-5.6-sol"
AUTODEVELOP_REASONING="max"
AUTODEVELOP_SCREEN_NAME="zigcss-autodevelop-$(printf '%s' "$AUTODEVELOP_ROOT" | shasum -a 256 | awk '{ print substr($1, 1, 12) }')"
AUTODEVELOP_PASS_TIMEOUT_SECS="${ZIGCSS_AUTODEVELOP_PASS_TIMEOUT_SECS:-7200}"
AUTODEVELOP_PUSH_TIMEOUT_SECS="${ZIGCSS_AUTODEVELOP_PUSH_TIMEOUT_SECS:-300}"
AUTODEVELOP_INTER_PASS_SECS="${ZIGCSS_AUTODEVELOP_INTER_PASS_SECS:-20}"
AUTODEVELOP_BLOCKED_RECHECK_SECS="${ZIGCSS_AUTODEVELOP_BLOCKED_RECHECK_SECS:-1800}"
AUTODEVELOP_RATE_LIMIT_MAX_SECS="${ZIGCSS_AUTODEVELOP_RATE_LIMIT_MAX_SECS:-3600}"
AUTODEVELOP_ERROR_BACKOFF_SECS="${ZIGCSS_AUTODEVELOP_ERROR_BACKOFF_SECS:-120}"
AUTODEVELOP_IDLE_POLL_SECS="${ZIGCSS_AUTODEVELOP_IDLE_POLL_SECS:-5}"
AUTODEVELOP_MAX_FAMILY_PASSES="${ZIGCSS_AUTODEVELOP_MAX_FAMILY_PASSES:-4}"
AUTODEVELOP_MAIN_BATCH_PASSES="${ZIGCSS_AUTODEVELOP_MAIN_BATCH_PASSES:-4}"

AUTODEVELOP_CALLER_UMASK="$(umask)"
umask 077
for directory in "$AUTODEVELOP_HOME" "$AUTODEVELOP_LOG_DIR" "$AUTODEVELOP_STATE_DIR" "$AUTODEVELOP_CACHE_DIR"; do
  if [ -L "$directory" ]; then
    printf 'zigcss autodevelop: state path must not be a symlink: %s\n' "$directory" >&2
    exit 1
  fi
done
mkdir -p "$AUTODEVELOP_LOG_DIR" "$AUTODEVELOP_STATE_DIR" "$AUTODEVELOP_CACHE_DIR"
if [ "$AUTODEVELOP_TEST_MODE" != 1 ]; then
  AUTODEVELOP_HOME_REAL="$(CDPATH= cd -- "$AUTODEVELOP_HOME" && pwd -P)"
  if [ "$AUTODEVELOP_HOME_REAL" != "$AUTODEVELOP_ROOT/.autodevelop" ]; then
    printf 'zigcss autodevelop: state escaped the isolated worktree\n' >&2
    exit 1
  fi
fi
chmod 700 "$AUTODEVELOP_HOME" "$AUTODEVELOP_LOG_DIR" "$AUTODEVELOP_STATE_DIR" "$AUTODEVELOP_CACHE_DIR"
for control in "$AUTODEVELOP_PAUSE_FILE" "$AUTODEVELOP_STOP_FILE" "$AUTODEVELOP_COMPLETE_FILE" "$AUTODEVELOP_RESUME_WIP_FILE"; do
  if [ -L "$control" ]; then
    printf 'zigcss autodevelop: control path must not be a symlink: %s\n' "$control" >&2
    exit 1
  fi
done
umask "$AUTODEVELOP_CALLER_UMASK"

autodevelop_die() {
  printf 'zigcss autodevelop: %s\n' "$*" >&2
  return 1
}

autodevelop_resolve_codex() {
  local candidate
  if [ -n "${ZIGCSS_AUTODEVELOP_CODEX_BIN:-}" ]; then
    printf '%s\n' "$ZIGCSS_AUTODEVELOP_CODEX_BIN"
    return
  fi
  for candidate in \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "$HOME/.local/bin/codex"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  command -v codex 2>/dev/null || true
}

AUTODEVELOP_CODEX_BIN="$(autodevelop_resolve_codex)"

autodevelop_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

autodevelop_log() {
  local level="$1"
  shift
  printf '%s [%-7s] %s\n' "$(autodevelop_timestamp)" "$level" "$*" | tee -a "$AUTODEVELOP_ORCHESTRATOR_LOG"
}

autodevelop_state_get() {
  local file="$AUTODEVELOP_STATE_DIR/$1"
  if [ -f "$file" ]; then
    cat "$file"
  else
    printf '%s\n' "${2-0}"
  fi
}

autodevelop_state_set() {
  local key="$1"
  local value="$2"
  local temporary="$AUTODEVELOP_STATE_DIR/.${key}.$$"
  case "$key" in
    *[!A-Za-z0-9._-]*) autodevelop_die "invalid state key: $key"; return 1 ;;
  esac
  printf '%s' "$value" > "$temporary"
  mv "$temporary" "$AUTODEVELOP_STATE_DIR/$key"
}

autodevelop_state_increment() {
  local key="$1"
  local value
  value="$(autodevelop_state_get "$key" 0)"
  case "$value" in
    ''|*[!0-9]*) value=0 ;;
  esac
  value=$((value + 1))
  autodevelop_state_set "$key" "$value"
  printf '%s\n' "$value"
}

autodevelop_valid_blocker_code() {
  local code="$1"
  [ "${#code}" -le 64 ] || return 1
  case "$code" in
    ''|*[!a-z0-9-]*|-*|*-|*--*) return 1 ;;
  esac
}

autodevelop_valid_work_package() {
  local package="$1"
  [ "${#package}" -le 64 ] || return 1
  case "$package" in
    ''|*[!A-Z0-9-]*|-*|*-|*--*) return 1 ;;
  esac
}

autodevelop_valid_gap_marker() {
  local package="$1"
  local family="$2"
  local result="$3"
  autodevelop_valid_work_package "$package" || return 1
  autodevelop_valid_gap_progress "$family" "$result"
}

autodevelop_valid_gap_progress() {
  local family="$1"
  local result="$2"
  autodevelop_valid_blocker_code "$family" || return 1
  case "$result" in
    REDUCED|CLOSED) return 0 ;;
    *) return 1 ;;
  esac
}

autodevelop_extract_gap_line() {
  tail -80 "$1" 2>/dev/null \
    | grep -v '<work-package>' \
    | grep -v '<stable-family>' \
    | grep -v '<REDUCED|CLOSED>' \
    | sed -nE '/^[[:space:]]*ZIGCSS-AUTODEVELOP-GAP:/p' \
    | tail -1 \
    | sed -nE 's/^[[:space:]]*(ZIGCSS-AUTODEVELOP-GAP:[[:space:]]+[A-Z0-9]+(-[A-Z0-9]+)*[[:space:]]+[a-z0-9]+(-[a-z0-9]+)*[[:space:]]+(REDUCED|CLOSED))[[:space:]]*$/\1/p'
}

autodevelop_gap_marker_count() {
  tail -80 "$1" 2>/dev/null \
    | grep -v '<work-package>' \
    | grep -v '<stable-family>' \
    | grep -v '<REDUCED|CLOSED>' \
    | sed -nE '/^[[:space:]]*ZIGCSS-AUTODEVELOP-GAP:/p' \
    | wc -l \
    | awk '{ print $1 }'
}

autodevelop_extract_gap_package() {
  autodevelop_extract_gap_line "$1" | awk '{ print $2 }'
}

autodevelop_extract_gap_family() {
  autodevelop_extract_gap_line "$1" | awk '{ print $3 }'
}

autodevelop_extract_gap_result() {
  autodevelop_extract_gap_line "$1" | awk '{ print $4 }'
}

autodevelop_record_gap_progress() {
  local family="$1"
  local result="$2"
  local prior count required
  autodevelop_valid_gap_progress "$family" "$result" || {
    autodevelop_die "invalid release-gap progress"
    return 1
  }
  required="$(autodevelop_state_get convergence-required '')"
  if [ "$result" = CLOSED ]; then
    if [ -n "$required" ] && [ "$family" != "$required" ]; then
      autodevelop_die "convergence review closed a different release-gap family"
      return 1
    fi
    autodevelop_state_set gap-family ''
    autodevelop_state_set gap-family-count 0
    rm -f "$AUTODEVELOP_STATE_DIR/convergence-required"
    printf '0\n'
    return
  fi
  if [ -n "$required" ]; then
    autodevelop_die "release-gap family requires closure before another reduction pass"
    return 1
  fi
  prior="$(autodevelop_state_get gap-family '')"
  if [ "$family" = "$prior" ]; then
    count="$(autodevelop_state_increment gap-family-count)"
  else
    autodevelop_state_set gap-family "$family"
    autodevelop_state_set gap-family-count 1
    count=1
  fi
  if [ "$count" -ge "$AUTODEVELOP_MAX_FAMILY_PASSES" ]; then
    autodevelop_state_set convergence-required "$family"
  fi
  printf '%s\n' "$count"
}

autodevelop_main_batch_advance() {
  local count
  count="$(autodevelop_state_increment main-batch-count)" || return 1
  if [ "$count" -ge "$AUTODEVELOP_MAIN_BATCH_PASSES" ]; then
    printf 'INTEGRATE %s\n' "$count"
  else
    printf 'RECOVERY %s\n' "$count"
  fi
}

autodevelop_should_integrate_main() {
  local decision="$1"
  local package="$2"
  local family="${3:-}"
  local result="${4:-}"
  [ "$decision" = INTEGRATE ] \
    || [ "$package" = NATIVE-009 ] \
    || { [ "$package" = NATIVE-007 ] \
      && [ "$family" = native-five-target-ci-throughput ] \
      && [ "$result" = CLOSED ]; }
}

autodevelop_last_run_field() {
  local key="$1"
  local record="$AUTODEVELOP_STATE_DIR/last-run.env"
  local matches
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  matches="$(sed -n "s/^${key}=//p" "$record")"
  [ "$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] || return 1
  printf '%s\n' "$matches"
}

autodevelop_prime_terminal_integration() {
  local head="$1"
  local class package family result after_head count target
  class="$(autodevelop_last_run_field CLASS)" || return 1
  package="$(autodevelop_last_run_field GAP_PACKAGE)" || return 1
  family="$(autodevelop_last_run_field GAP_FAMILY)" || return 1
  result="$(autodevelop_last_run_field GAP_RESULT)" || return 1
  after_head="$(autodevelop_last_run_field AFTER_HEAD)" || return 1
  [ "$class" = PROGRESS ] || return 1
  [ "$after_head" = "$head" ] || return 1
  autodevelop_should_integrate_main RECOVERY "$package" "$family" "$result" || return 1

  count="$(autodevelop_state_get main-batch-count 0)"
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  target=$((AUTODEVELOP_MAIN_BATCH_PASSES - 1))
  if [ "$count" -lt "$target" ]; then
    autodevelop_state_set main-batch-count "$target"
  fi
}

autodevelop_record_blocker() {
  local code="$1"
  local prior
  autodevelop_valid_blocker_code "$code" || {
    autodevelop_die "invalid stable blocker code"
    return 1
  }
  prior="$(autodevelop_state_get blocked-code '')"
  if [ "$code" = "$prior" ]; then
    autodevelop_state_increment blocked-count
  else
    autodevelop_state_set blocked-code "$code"
    autodevelop_state_set blocked-count 1
    printf '1\n'
  fi
}

autodevelop_git_status() {
  git -C "$AUTODEVELOP_ROOT" status --porcelain=v1
}

autodevelop_git_clean() {
  [ -z "$(autodevelop_git_status)" ]
}

autodevelop_dirty_fingerprint() {
  git -C "$AUTODEVELOP_ROOT" status --porcelain=v1 -z | shasum -a 256 | awk '{print $1}'
}

autodevelop_record_resume_wip() {
  autodevelop_state_set resume-wip "$(autodevelop_dirty_fingerprint)"
}

autodevelop_require_positive_integer() {
  local value="$1"
  local label="$2"
  case "$value" in
    ''|0|*[!0-9]*) autodevelop_die "$label must be a positive integer"; return 1 ;;
  esac
}

autodevelop_branch_allowed() {
  local branch="$1"
  local test_mode="${2:-$AUTODEVELOP_TEST_MODE}"
  if [ "$test_mode" = 1 ]; then return 0; fi
  [ "$test_mode" = 0 ] || return 1
  case "$branch" in
    vale/*) return 0 ;;
    *) return 1 ;;
  esac
}

autodevelop_require_repository() {
  local branch
  [ -f "$AUTODEVELOP_ROOT/DEVELOPMENT_PLAN.md" ] || {
    autodevelop_die "missing DEVELOPMENT_PLAN.md"
    return 1
  }
  [ -f "$AUTODEVELOP_ROOT/DEVELOPMENT_STATUS.md" ] || {
    autodevelop_die "missing DEVELOPMENT_STATUS.md"
    return 1
  }
  git -C "$AUTODEVELOP_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    autodevelop_die "runner root is not a Git worktree"
    return 1
  }
  branch="$(git -C "$AUTODEVELOP_ROOT" branch --show-current)"
  autodevelop_branch_allowed "$branch" || {
    autodevelop_die "the isolated runner requires a vale/* branch"
    return 1
  }
  if [ -n "$(git -C "$AUTODEVELOP_ROOT" diff --name-only --diff-filter=U)" ]; then
    autodevelop_die "unmerged paths require operator recovery"
    return 1
  fi
  autodevelop_require_positive_integer "$AUTODEVELOP_PASS_TIMEOUT_SECS" ZIGCSS_AUTODEVELOP_PASS_TIMEOUT_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_PUSH_TIMEOUT_SECS" ZIGCSS_AUTODEVELOP_PUSH_TIMEOUT_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_INTER_PASS_SECS" ZIGCSS_AUTODEVELOP_INTER_PASS_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_BLOCKED_RECHECK_SECS" ZIGCSS_AUTODEVELOP_BLOCKED_RECHECK_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_RATE_LIMIT_MAX_SECS" ZIGCSS_AUTODEVELOP_RATE_LIMIT_MAX_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_ERROR_BACKOFF_SECS" ZIGCSS_AUTODEVELOP_ERROR_BACKOFF_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_IDLE_POLL_SECS" ZIGCSS_AUTODEVELOP_IDLE_POLL_SECS || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_MAX_FAMILY_PASSES" ZIGCSS_AUTODEVELOP_MAX_FAMILY_PASSES || return 1
  autodevelop_require_positive_integer "$AUTODEVELOP_MAIN_BATCH_PASSES" ZIGCSS_AUTODEVELOP_MAIN_BATCH_PASSES || return 1
}

autodevelop_extract_status() {
  tail -80 "$1" 2>/dev/null \
    | grep -v '<short summary>' \
    | grep -v '<reason>' \
    | sed -nE 's/^[[:space:]]*ZIGCSS-AUTODEVELOP-STATUS:[[:space:]]*(PROGRESS|BLOCKED|COMPLETE)([[:space:]].*)?$/\1/p' \
    | tail -1
}

autodevelop_extract_blocker_code() {
  tail -80 "$1" 2>/dev/null \
    | grep -v '<stable-code>' \
    | sed -nE '/^[[:space:]]*ZIGCSS-AUTODEVELOP-STATUS:[[:space:]]*BLOCKED([[:space:]].*)?$/p' \
    | tail -1 \
    | sed -nE 's/^[[:space:]]*ZIGCSS-AUTODEVELOP-STATUS:[[:space:]]*BLOCKED[[:space:]]+([a-z0-9]+(-[a-z0-9]+)*):[[:space:]]+.+$/\1/p' \
    | cut -c1-80
}

autodevelop_extract_reason() {
  tail -80 "$1" 2>/dev/null \
    | grep -v '<reason>' \
    | sed -nE 's/^[[:space:]]*ZIGCSS-AUTODEVELOP-STATUS:[[:space:]]*BLOCKED[[:space:]]*//p' \
    | tail -1 \
    | sed -E 's/^[a-z0-9]+(-[a-z0-9]+)*:[[:space:]]*//' \
    | cut -c1-500
}

autodevelop_classify_pass() {
  local rc="$1"
  local output="$2"
  local final_message="${3:-$output}"
  local status blocker_code gap_count gap_package gap_family gap_result size
  status="$(autodevelop_extract_status "$final_message")"
  if [ "$rc" -eq 0 ] && [ -n "$status" ]; then
    if [ "$status" = BLOCKED ]; then
      blocker_code="$(autodevelop_extract_blocker_code "$final_message")"
      if ! autodevelop_valid_blocker_code "$blocker_code"; then
        printf 'ERROR\n'
        return
      fi
    fi
    if [ "$status" = PROGRESS ]; then
      gap_count="$(autodevelop_gap_marker_count "$final_message")"
      gap_package="$(autodevelop_extract_gap_package "$final_message")"
      gap_family="$(autodevelop_extract_gap_family "$final_message")"
      gap_result="$(autodevelop_extract_gap_result "$final_message")"
      if [ "$gap_count" -ne 1 ] || ! autodevelop_valid_gap_marker "$gap_package" "$gap_family" "$gap_result"; then
        printf 'ERROR\n'
        return
      fi
    fi
    printf '%s\n' "$status"
    return
  fi
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    printf 'TIMEOUT\n'
    return
  fi
  size="$(wc -c < "$output" 2>/dev/null || printf '99999')"
  if [ "$rc" -ne 0 ] && [ "$size" -lt 4096 ] \
     && grep -Eiq 'failed to authenticate|invalid authentication|invalid api key|token (is )?(expired|revoked)|not logged in|please (run|use).{0,20}log.?in|status 401' "$output" 2>/dev/null; then
    printf 'AUTH\n'
    return
  fi
  if [ "$rc" -ne 0 ] \
     && tail -100 "$output" 2>/dev/null | grep -Eiq 'usage limit (reached|exceeded)|rate.?limit.?((was )?(reached|exceeded)|error)|too many requests|error 429|status 429|quota exceeded|insufficient_quota|weekly limit (reached|exceeded)|you.?ve (hit|reached) your'; then
    printf 'RATE_LIMIT\n'
    return
  fi
  printf 'ERROR\n'
}

autodevelop_rate_limit_delay() {
  local output="$1"
  local parsed
  parsed="$(tail -100 "$output" 2>/dev/null | perl -0777 -ne '
    my $t = lc($_);
    if ($t =~ /in\s+(\d+)\s*hour/) { print $1 * 3600; exit }
    if ($t =~ /in\s+(\d+)\s*min/)  { print $1 * 60; exit }
    if ($t =~ /in\s+(\d+)\s*sec/)  { print $1; exit }
  ' 2>/dev/null)"
  case "$parsed" in
    ''|*[!0-9]*) parsed=600 ;;
  esac
  if [ "$parsed" -gt "$AUTODEVELOP_RATE_LIMIT_MAX_SECS" ]; then
    parsed="$AUTODEVELOP_RATE_LIMIT_MAX_SECS"
  fi
  if [ "$parsed" -lt 60 ]; then parsed=60; fi
  printf '%s\n' "$parsed"
}

autodevelop_run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 20 "$seconds" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 20 "$seconds" "$@"
    return $?
  fi

  "$@" &
  local child=$!
  (
    sleep "$seconds"
    kill -TERM "$child" 2>/dev/null || true
    sleep 20
    kill -KILL "$child" 2>/dev/null || true
  ) &
  local watcher=$!
  local rc=0
  wait "$child" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

autodevelop_sleep_interruptible() {
  local remaining="$1"
  local slice
  while [ "$remaining" -gt 0 ]; do
    [ -f "$AUTODEVELOP_STOP_FILE" ] && return 1
    [ -f "$AUTODEVELOP_PAUSE_FILE" ] && return 2
    slice=5
    if [ "$remaining" -lt "$slice" ]; then slice="$remaining"; fi
    sleep "$slice"
    remaining=$((remaining - slice))
  done
  return 0
}

autodevelop_notify_local() {
  local title="$1"
  local body="$2"
  if command -v osascript >/dev/null 2>&1; then
    title="$(printf '%s' "$title" | tr '"' "'")"
    body="$(printf '%s' "$body" | tr '"' "'")"
    osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 || true
  fi
  autodevelop_log ALERT "$title — $body"
}
