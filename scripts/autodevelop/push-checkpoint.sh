#!/usr/bin/env bash
# Push one already-green checkpoint to the approved recovery branch, optionally integrating main.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

REMOTE=origin
MAIN_BRANCH=main
MODE="${1:-push}"
if [ "$#" -gt 1 ] || { [ "$MODE" != push ] && [ "$MODE" != --check ] && [ "$MODE" != --recovery-only ]; }; then
  autodevelop_die "usage: push-checkpoint.sh [--check|--recovery-only]"
  exit 2
fi

approved_remote_url() {
  if [ "$AUTODEVELOP_TEST_MODE" = 1 ]; then return 0; fi
  case "$1" in
    https://github.com/vyakymenko/zigcss.git|\
    https://vyakymenko@github.com/vyakymenko/zigcss.git|\
    git@github.com:vyakymenko/zigcss.git|\
    ssh://git@github.com/vyakymenko/zigcss.git) return 0 ;;
    *) return 1 ;;
  esac
}

autodevelop_require_repository || exit 1
BRANCH="$(git -C "$AUTODEVELOP_ROOT" branch --show-current)"
case "$BRANCH" in
  vale/*) : ;;
  *) autodevelop_die "automatic push requires the current vale/* branch"; exit 1 ;;
esac

REMOTE_URL="$(git -C "$AUTODEVELOP_ROOT" remote get-url --push "$REMOTE" 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ] || ! approved_remote_url "$REMOTE_URL"; then
  autodevelop_die "origin push URL is not the approved vyakymenko/zigcss repository"
  exit 1
fi

if [ "$MODE" = --check ]; then
  printf 'push: %s -> refs/heads/%s every green pass; refs/heads/%s in bounded batches (non-force; validated)\n' \
    "$REMOTE" "$BRANCH" "$MAIN_BRANCH"
  exit 0
fi

if ! autodevelop_git_clean; then
  autodevelop_die "automatic push requires a clean worktree"
  exit 1
fi

HEAD="$(git -C "$AUTODEVELOP_ROOT" rev-parse HEAD)"
INCLUDE_MAIN=1
if [ "$MODE" = --recovery-only ]; then INCLUDE_MAIN=0; fi
autodevelop_log INFO "push start remote=$REMOTE branch=$BRANCH main=$INCLUDE_MAIN head=${HEAD%????????????????????????????????}"
PUSH_RC=0
if [ "$INCLUDE_MAIN" -eq 1 ]; then
  GIT_TERMINAL_PROMPT=0 autodevelop_run_with_timeout "$AUTODEVELOP_PUSH_TIMEOUT_SECS" \
    git -C "$AUTODEVELOP_ROOT" push --porcelain --atomic "$REMOTE" \
      "HEAD:refs/heads/$BRANCH" \
      "HEAD:refs/heads/$MAIN_BRANCH" || PUSH_RC=$?
else
  GIT_TERMINAL_PROMPT=0 autodevelop_run_with_timeout "$AUTODEVELOP_PUSH_TIMEOUT_SECS" \
    git -C "$AUTODEVELOP_ROOT" push --porcelain "$REMOTE" \
      "HEAD:refs/heads/$BRANCH" || PUSH_RC=$?
fi
if [ "$PUSH_RC" -ne 0 ]; then
  autodevelop_die "checkpoint push failed or exceeded ${AUTODEVELOP_PUSH_TIMEOUT_SECS}s"
  exit 1
fi

REMOTE_TMP="$AUTODEVELOP_STATE_DIR/.remote-head.$$"
rm -f "$REMOTE_TMP"
READ_RC=0
GIT_TERMINAL_PROMPT=0 autodevelop_run_with_timeout "$AUTODEVELOP_PUSH_TIMEOUT_SECS" \
  git -C "$AUTODEVELOP_ROOT" ls-remote --exit-code --heads "$REMOTE" \
    "refs/heads/$BRANCH" \
    "refs/heads/$MAIN_BRANCH" \
  > "$REMOTE_TMP" || READ_RC=$?
if [ "$READ_RC" -ne 0 ]; then
  rm -f "$REMOTE_TMP"
  autodevelop_die "pushed branch could not be read back from origin"
  exit 1
fi
REMOTE_LIST="$(cat "$REMOTE_TMP")"
rm -f "$REMOTE_TMP"
REMOTE_BRANCH_HEAD="$(printf '%s\n' "$REMOTE_LIST" | awk -v ref="refs/heads/$BRANCH" '$2 == ref { print $1 }')"
REMOTE_MAIN_HEAD="$(printf '%s\n' "$REMOTE_LIST" | awk -v ref="refs/heads/$MAIN_BRANCH" '$2 == ref { print $1 }')"
if [ "$REMOTE_BRANCH_HEAD" != "$HEAD" ]; then
  autodevelop_die "origin recovery branch does not match the pushed checkpoint"
  exit 1
fi
if [ "$INCLUDE_MAIN" -eq 1 ] && [ "$REMOTE_MAIN_HEAD" != "$HEAD" ]; then
  autodevelop_die "origin main does not match the integrated checkpoint"
  exit 1
fi
if [ "$(git -C "$AUTODEVELOP_ROOT" branch --show-current)" != "$BRANCH" ] \
   || [ "$(git -C "$AUTODEVELOP_ROOT" rev-parse HEAD)" != "$HEAD" ] \
   || ! autodevelop_git_clean; then
  autodevelop_die "local branch changed while the checkpoint was pushed"
  exit 1
fi

autodevelop_state_set last-pushed-head "$HEAD"
autodevelop_state_set last-pushed-branch "$BRANCH"
if [ -n "$REMOTE_MAIN_HEAD" ]; then
  autodevelop_state_set last-pushed-main-head "$REMOTE_MAIN_HEAD"
fi
autodevelop_log INFO "push verified remote=$REMOTE branch=$BRANCH main=$INCLUDE_MAIN head=${HEAD%????????????????????????????????}"
