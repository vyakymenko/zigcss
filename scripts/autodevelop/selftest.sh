#!/usr/bin/env bash
# Hermetic tests for classification/state primitives. No model call or repo mutation.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
TMP="$(mktemp -d /tmp/zigcss-autodevelop-selftest.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export ZIGCSS_AUTODEVELOP_STATE_DIR="$TMP/state-root"
export ZIGCSS_AUTODEVELOP_TEST_MODE=1
CALLER_UMASK="$(umask)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

PASS=0
FAIL=0

assert_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: received [%s], expected [%s]\n' "$label" "$actual" "$expected" >&2
  fi
}

fixture() {
  printf '%s\n' "$2" > "$TMP/$1"
}

assert_equal "$(umask)" "$CALLER_UMASK" 'caller umask restored'
assert_equal "$(if autodevelop_branch_allowed vale/recovery 0; then printf allowed; else printf rejected; fi)" allowed 'production vale branch accepted'
assert_equal "$(if autodevelop_branch_allowed main 0; then printf allowed; else printf rejected; fi)" rejected 'production main branch rejected'
assert_equal "$(if autodevelop_branch_allowed '' 1; then printf allowed; else printf rejected; fi)" allowed 'test-mode detached checkout accepted'

fixture progress 'ZIGCSS-AUTODEVELOP-GAP: NSASS-011 sass-callable-reexport-depth REDUCED
ZIGCSS-AUTODEVELOP-STATUS: PROGRESS NSASS-011 checkpointed'
assert_equal "$(autodevelop_extract_status "$TMP/progress")" PROGRESS 'progress tag'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/progress")" PROGRESS 'progress classification'
assert_equal "$(autodevelop_extract_gap_package "$TMP/progress")" NSASS-011 'release-gap package'
assert_equal "$(autodevelop_extract_gap_family "$TMP/progress")" sass-callable-reexport-depth 'stable release-gap family'
assert_equal "$(autodevelop_extract_gap_result "$TMP/progress")" REDUCED 'release-gap result'
assert_equal "$(if autodevelop_valid_gap_marker NSASS-011 sass-callable-reexport-depth REDUCED; then printf valid; else printf invalid; fi)" valid 'release-gap marker accepted'
assert_equal "$(if autodevelop_valid_gap_marker 'NSASS 011' sass-callable-reexport-depth REDUCED; then printf valid; else printf invalid; fi)" invalid 'malformed work package rejected'
assert_equal "$(if autodevelop_valid_gap_marker NSASS-011 Sass_Depth REDUCED; then printf valid; else printf invalid; fi)" invalid 'malformed family rejected'
assert_equal "$(if autodevelop_valid_gap_marker NSASS-011 sass-callable-reexport-depth EXPANDED; then printf valid; else printf invalid; fi)" invalid 'non-convergent gap result rejected'

fixture missing-gap 'ZIGCSS-AUTODEVELOP-STATUS: PROGRESS NSASS-011 checkpointed'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/missing-gap")" ERROR 'progress without release-gap evidence rejected'

fixture duplicate-gap 'ZIGCSS-AUTODEVELOP-GAP: NSASS-011 sass-callable-reexport-depth REDUCED
ZIGCSS-AUTODEVELOP-GAP: NSASS-011 sass-callable-reexport-depth CLOSED
ZIGCSS-AUTODEVELOP-STATUS: PROGRESS NSASS-011 checkpointed'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/duplicate-gap")" ERROR 'multiple release-gap markers rejected'

fixture invalid-last-gap 'ZIGCSS-AUTODEVELOP-GAP: NSASS-011 sass-callable-reexport-depth REDUCED
ZIGCSS-AUTODEVELOP-GAP: missing fields
ZIGCSS-AUTODEVELOP-STATUS: PROGRESS NSASS-011 checkpointed'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/invalid-last-gap")" ERROR 'invalid final release-gap marker cannot reuse earlier evidence'

fixture blocked 'ZIGCSS-AUTODEVELOP-STATUS: BLOCKED controlled-benchmark-archive: irreversible signing policy'
assert_equal "$(autodevelop_extract_blocker_code "$TMP/blocked")" 'controlled-benchmark-archive' 'stable blocker code'
assert_equal "$(autodevelop_extract_reason "$TMP/blocked")" 'irreversible signing policy' 'blocked reason excludes stable code'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/blocked")" BLOCKED 'blocked classification'

fixture blocked-reworded 'ZIGCSS-AUTODEVELOP-STATUS: BLOCKED controlled-benchmark-archive: scheduled evidence is still unavailable'
assert_equal "$(autodevelop_extract_blocker_code "$TMP/blocked-reworded")" 'controlled-benchmark-archive' 'reworded blocker keeps identity'

fixture blocked-without-code 'ZIGCSS-AUTODEVELOP-STATUS: BLOCKED irreversible signing policy'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/blocked-without-code")" ERROR 'blocker without stable code rejected'

fixture blocked-without-reason 'ZIGCSS-AUTODEVELOP-STATUS: BLOCKED controlled-benchmark-archive:'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/blocked-without-reason")" ERROR 'blocker without reason rejected'

fixture blocked-last-marker 'ZIGCSS-AUTODEVELOP-STATUS: BLOCKED controlled-benchmark-archive: valid earlier marker
ZIGCSS-AUTODEVELOP-STATUS: BLOCKED missing stable code'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/blocked-last-marker")" ERROR 'invalid last blocker cannot reuse earlier code'
assert_equal "$(if autodevelop_valid_blocker_code controlled-benchmark-archive; then printf valid; else printf invalid; fi)" valid 'lowercase kebab blocker code accepted'
assert_equal "$(if autodevelop_valid_blocker_code invalid_Code; then printf valid; else printf invalid; fi)" invalid 'non-kebab blocker code rejected'
LONG_BLOCKER_CODE="$(printf 'a%.0s' {1..65})"
assert_equal "$(if autodevelop_valid_blocker_code "$LONG_BLOCKER_CODE"; then printf valid; else printf invalid; fi)" invalid 'overlong blocker code rejected'

fixture complete 'ZIGCSS-AUTODEVELOP-STATUS: COMPLETE'
assert_equal "$(autodevelop_classify_pass 0 "$TMP/complete")" COMPLETE 'complete classification'

PROMPT_OUTPUT="$TMP/run-pass-prompt"
bash "$HERE/run-pass.sh" --print-prompt > "$PROMPT_OUTPUT"
assert_equal "$(grep -Fc 'Milestone 10, NATIVE-009, and the REL-010 stable v0.6.0 publication terminal are verified and closed.' "$PROMPT_OUTPUT")" 1 'prompt closes the stable publication terminal'
assert_equal "$(grep -Fc 'The current autonomous program is complete under ADR-016' "$PROMPT_OUTPUT")" 1 'prompt closes the current autonomous program'
assert_equal "$(grep -Fc 'BENCH-007 is deferred external' "$PROMPT_OUTPUT")" 1 'prompt defers optional controlled benchmark evidence'
assert_equal "$(grep -Fc 'Do not provision infrastructure or spend project funds' "$PROMPT_OUTPUT")" 1 'prompt preserves the no-funded-infrastructure decision'
assert_equal "$(grep -Fc 'emit COMPLETE after read-only orientation' "$PROMPT_OUTPUT")" 1 'prompt selects terminal completion'
assert_equal "$(if grep -Fq 'stable code controlled-benchmark-archive' "$PROMPT_OUTPUT"; then printf stale; else printf absent; fi)" absent 'prompt removes the inactive benchmark blocker'
assert_equal "$(grep -Fc 'Stable publication authority was successfully consumed and closed on 2026-08-18.' "$PROMPT_OUTPUT")" 1 'prompt closes stable publication authority'
assert_equal "$(if grep -Fq 'REL-010 stable-promotion sequence is active.' "$PROMPT_OUTPUT"; then printf stale; else printf absent; fi)" absent 'prompt removes stale stable-promotion work'
assert_equal "$(grep -Fc 'Never move, delete, recreate, or republish `v0.6.0-rc.2`, `v0.6.0`, npm `0.6.0-rc.2`, or npm `0.6.0`' "$PROMPT_OUTPUT")" 1 'prompt preserves immutable public releases'
assert_equal "$(grep -Fc 'A sibling search is inspection, not an automatic work queue.' "$PROMPT_OUTPUT")" 1 'prompt forbids unbounded sibling queues'
assert_equal "$(grep -Fc 'predeclared finite terminal bound' "$PROMPT_OUTPUT")" 1 'prompt requires finite numeric bounds'
assert_equal "$(grep -Fc 'ZIGCSS-AUTODEVELOP-GAP:' "$PROMPT_OUTPUT")" 1 'prompt retains release-gap protocol for future progress work'

autodevelop_state_set convergence-required sass-callable-reexport-depth
CONVERGENCE_PROMPT="$TMP/run-pass-convergence-prompt"
bash "$HERE/run-pass.sh" --print-prompt > "$CONVERGENCE_PROMPT"
assert_equal "$(grep -Fc 'CONVERGENCE REVIEW REQUIRED: sass-callable-reexport-depth' "$CONVERGENCE_PROMPT")" 1 'threshold injects convergence review'
assert_equal "$(grep -Fc 'must report the same family as CLOSED' "$CONVERGENCE_PROMPT")" 1 'convergence review must close the family'
rm -f "$AUTODEVELOP_STATE_DIR/convergence-required"

autodevelop_state_set convergence-required 'malformed family'
MALFORMED_CONVERGENCE_RC=0
bash "$HERE/run-pass.sh" --print-prompt > /dev/null 2>&1 || MALFORMED_CONVERGENCE_RC=$?
assert_equal "$MALFORMED_CONVERGENCE_RC" 1 'malformed stored convergence family rejected'
rm -f "$AUTODEVELOP_STATE_DIR/convergence-required"

fixture prompt-echo 'ZIGCSS-AUTODEVELOP-STATUS: BLOCKED <stable-code>: <reason>'
assert_equal "$(autodevelop_classify_pass 1 "$TMP/prompt-echo")" ERROR 'prompt marker ignored'

fixture echoed-runtime-error 'user
Do not sleep or wait for rate limits.
ZIGCSS-AUTODEVELOP-STATUS: COMPLETE
ERROR: The selected model requires a newer version of Codex.'
fixture empty-final ''
assert_equal "$(autodevelop_extract_status "$TMP/empty-final")" '' 'empty final message has no status'
assert_equal "$(autodevelop_classify_pass 1 "$TMP/echoed-runtime-error" "$TMP/empty-final")" ERROR 'echoed prompt cannot classify operational failure'

fixture rate 'Usage limit reached. Try again in 30 minutes.'
assert_equal "$(autodevelop_classify_pass 1 "$TMP/rate")" RATE_LIMIT 'rate classification'
assert_equal "$(autodevelop_rate_limit_delay "$TMP/rate")" 1800 'rate delay'

fixture auth 'Not logged in. Please run codex login to authenticate.'
assert_equal "$(autodevelop_classify_pass 1 "$TMP/auth")" AUTH 'auth classification'
assert_equal "$(autodevelop_classify_pass 124 "$TMP/rate")" TIMEOUT 'timeout precedence'

autodevelop_state_set counter 4
assert_equal "$(autodevelop_state_increment counter)" 5 'atomic counter'
assert_equal "$(autodevelop_record_blocker controlled-benchmark-archive)" 1 'new blocker starts at one'
assert_equal "$(autodevelop_record_blocker controlled-benchmark-archive)" 2 'same stable blocker increments'
assert_equal "$(autodevelop_record_blocker controlled-benchmark-archive)" 3 'same stable blocker reaches pause threshold'
assert_equal "$(autodevelop_record_blocker distinct-authority-decision)" 1 'different stable blocker resets count'

assert_equal "$(autodevelop_record_gap_progress sass-callable-reexport-depth REDUCED)" 1 'new release-gap family starts at one'
assert_equal "$(autodevelop_record_gap_progress sass-callable-reexport-depth REDUCED)" 2 'same release-gap family increments'
assert_equal "$(autodevelop_record_gap_progress sass-callable-reexport-depth REDUCED)" 3 'release-gap family reaches pre-threshold count'
assert_equal "$(autodevelop_record_gap_progress sass-callable-reexport-depth REDUCED)" 4 'release-gap family reaches convergence threshold'
assert_equal "$(cat "$AUTODEVELOP_STATE_DIR/convergence-required")" sass-callable-reexport-depth 'threshold requires convergence review'
assert_equal "$(autodevelop_record_gap_progress sass-callable-reexport-depth CLOSED)" 0 'closed family resets count'
assert_equal "$(if [ -e "$AUTODEVELOP_STATE_DIR/convergence-required" ]; then printf present; else printf absent; fi)" absent 'closed family clears convergence state'
assert_equal "$(autodevelop_record_gap_progress native-less-values REDUCED)" 1 'different release-gap family starts independently'

autodevelop_state_set main-batch-count 0
assert_equal "$(autodevelop_main_batch_advance)" 'RECOVERY 1' 'first green pass remains recovery-only'
assert_equal "$(autodevelop_main_batch_advance)" 'RECOVERY 2' 'second green pass remains recovery-only'
assert_equal "$(autodevelop_main_batch_advance)" 'RECOVERY 3' 'third green pass remains recovery-only'
assert_equal "$(autodevelop_main_batch_advance)" 'INTEGRATE 4' 'fourth green pass requires main integration'
autodevelop_state_set main-batch-count 0
assert_equal "$(autodevelop_state_get main-batch-count)" 0 'successful main integration can reset its batch'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY NSASS-011 native-sass-evaluation CLOSED; then printf yes; else printf no; fi)" no 'ordinary early batch stays recovery-only'
assert_equal "$(if autodevelop_should_integrate_main INTEGRATE NSASS-011 native-sass-evaluation CLOSED; then printf yes; else printf no; fi)" yes 'batch threshold integrates main'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY NATIVE-009 native-release-evidence REDUCED; then printf yes; else printf no; fi)" yes 'native release validation integrates main immediately'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY REL-010 stable-release-promotion REDUCED; then printf yes; else printf no; fi)" yes 'stable promotion validation integrates main immediately'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY NATIVE-007 native-five-target-ci-throughput CLOSED; then printf yes; else printf no; fi)" yes 'native hosted-validation terminal integrates main immediately'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY NATIVE-007 native-five-target-ci-throughput REDUCED; then printf yes; else printf no; fi)" no 'incomplete native hosted-validation family stays batched'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY NATIVE-007 native-zero-dependency-package CLOSED; then printf yes; else printf no; fi)" no 'ordinary native package family stays batched'
assert_equal "$(if autodevelop_should_integrate_main RECOVERY NSASS-012 native-five-target-ci-throughput CLOSED; then printf yes; else printf no; fi)" no 'terminal family cannot widen immediate integration to another package'

FAKE_CODEX="$TMP/fake-codex"
FAKE_ARGS="$TMP/fake-args"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$@" > "$ZIGCSS_FAKE_ARGS"' \
  'final_message=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  if [ "$1" = "--output-last-message" ]; then shift; final_message="$1"; fi' \
  '  shift' \
  'done' \
  'test -n "$final_message"' \
  'printf "ZIGCSS-AUTODEVELOP-STATUS: BLOCKED synthetic-test-blocker: test-only external condition\n" > "$final_message"' \
  > "$FAKE_CODEX"
chmod +x "$FAKE_CODEX"
PASS_HOME="$TMP/pass-state"
ZIGCSS_AUTODEVELOP_STATE_DIR="$PASS_HOME" \
ZIGCSS_AUTODEVELOP_TEST_MODE=1 \
ZIGCSS_AUTODEVELOP_CODEX_BIN="$FAKE_CODEX" \
ZIGCSS_FAKE_ARGS="$FAKE_ARGS" \
  bash "$HERE/run-pass.sh" > "$TMP/fake-pass.log" 2>&1
assert_equal "$(grep '^CLASS=' "$PASS_HOME/state/last-run.env" | cut -d= -f2)" BLOCKED 'fake pass classification'
assert_equal "$(grep '^BLOCKER_CODE=' "$PASS_HOME/state/last-run.env" | cut -d= -f2)" synthetic-test-blocker 'fake pass records stable blocker code'
assert_equal "$(grep -xc -- '--ephemeral' "$FAKE_ARGS")" 1 'ephemeral CLI flag'
assert_equal "$(grep -xc -- '--output-last-message' "$FAKE_ARGS")" 1 'isolated final-message CLI flag'
assert_equal "$(grep -xc -- 'gpt-5.6-sol' "$FAKE_ARGS")" 1 'fixed model argument'
assert_equal "$(grep -xc -- 'model_reasoning_effort="max"' "$FAKE_ARGS")" 1 'fixed reasoning argument'
if autodevelop_git_clean; then
  assert_equal "$(if [ -e "$PASS_HOME/state/resume-wip" ]; then printf 'present'; else printf 'absent'; fi)" absent 'clean pass leaves no WIP marker'
else
  assert_equal "$(cat "$PASS_HOME/state/resume-wip")" "$(autodevelop_dirty_fingerprint)" 'interrupted WIP fingerprint'
fi

PUSH_REPO="$TMP/push-repo"
PUSH_REMOTE="$TMP/push-remote.git"
mkdir -p "$PUSH_REPO/scripts/autodevelop"
cp "$HERE/lib.sh" "$HERE/push-checkpoint.sh" "$PUSH_REPO/scripts/autodevelop/"
git init -q --bare "$PUSH_REMOTE"
git -C "$PUSH_REPO" init -q
git -C "$PUSH_REPO" config user.name 'ZigCSS selftest'
git -C "$PUSH_REPO" config user.email 'zigcss-selftest@example.invalid'
printf 'plan\n' > "$PUSH_REPO/DEVELOPMENT_PLAN.md"
printf 'status\n' > "$PUSH_REPO/DEVELOPMENT_STATUS.md"
printf '.autodevelop/\n' > "$PUSH_REPO/.gitignore"
git -C "$PUSH_REPO" add DEVELOPMENT_PLAN.md DEVELOPMENT_STATUS.md .gitignore scripts/autodevelop/lib.sh scripts/autodevelop/push-checkpoint.sh
git -C "$PUSH_REPO" commit -q -m baseline
git -C "$PUSH_REPO" checkout -q -b vale/selftest
git -C "$PUSH_REPO" remote add origin "$PUSH_REMOTE"

UNAPPROVED_REMOTE_RC=0
env -u ZIGCSS_AUTODEVELOP_STATE_DIR ZIGCSS_AUTODEVELOP_TEST_MODE=0 \
  bash "$PUSH_REPO/scripts/autodevelop/push-checkpoint.sh" --check > /dev/null 2>&1 || UNAPPROVED_REMOTE_RC=$?
assert_equal "$UNAPPROVED_REMOTE_RC" 1 'unapproved production push remote rejected'

PUSH_STATE="$TMP/push-state"
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$PUSH_STATE" \
  bash "$PUSH_REPO/scripts/autodevelop/push-checkpoint.sh" --recovery-only > "$TMP/recovery-push.log" 2>&1
PUSH_HEAD="$(git -C "$PUSH_REPO" rev-parse HEAD)"
assert_equal "$(git --git-dir="$PUSH_REMOTE" rev-parse refs/heads/vale/selftest)" "$PUSH_HEAD" 'green checkpoint pushed to recovery branch'
assert_equal "$(if git --git-dir="$PUSH_REMOTE" show-ref --verify --quiet refs/heads/main; then printf present; else printf absent; fi)" absent 'recovery-only push does not trigger main'
assert_equal "$(cat "$PUSH_STATE/state/last-pushed-head")" "$PUSH_HEAD" 'recovery-only head recorded'

{
  printf 'CLASS=PROGRESS\n'
  printf 'GAP_PACKAGE=NATIVE-007\n'
  printf 'GAP_FAMILY=native-five-target-ci-throughput\n'
  printf 'GAP_RESULT=CLOSED\n'
  printf 'AFTER_HEAD=%s\n' "$PUSH_HEAD"
} > "$PUSH_STATE/state/last-run.env"
printf '2' > "$PUSH_STATE/state/main-batch-count"
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$PUSH_STATE" \
  bash "$PUSH_REPO/scripts/autodevelop/push-checkpoint.sh" --recovery-only > "$TMP/terminal-recovery-push.log" 2>&1
assert_equal "$(cat "$PUSH_STATE/state/main-batch-count")" 3 'validated hosted terminal primes the existing integration decision'
assert_equal "$(if git --git-dir="$PUSH_REMOTE" show-ref --verify --quiet refs/heads/main; then printf present; else printf absent; fi)" absent 'terminal recovery push leaves main integration supervisor-owned'

ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$PUSH_STATE" \
  bash "$PUSH_REPO/scripts/autodevelop/push-checkpoint.sh" > "$TMP/push.log" 2>&1
assert_equal "$(git --git-dir="$PUSH_REMOTE" rev-parse refs/heads/vale/selftest)" "$PUSH_HEAD" 'green checkpoint pushed to exact branch'
assert_equal "$(git --git-dir="$PUSH_REMOTE" rev-parse refs/heads/main)" "$PUSH_HEAD" 'green checkpoint atomically integrated to main'
assert_equal "$(cat "$PUSH_STATE/state/last-pushed-head")" "$PUSH_HEAD" 'pushed head recorded'
assert_equal "$(cat "$PUSH_STATE/state/last-pushed-branch")" vale/selftest 'pushed branch recorded'
assert_equal "$(cat "$PUSH_STATE/state/last-pushed-main-head")" "$PUSH_HEAD" 'integrated main head recorded'

DIVERGED_HEAD="$(printf 'independent remote main\n' | git -C "$PUSH_REPO" commit-tree "$PUSH_HEAD^{tree}")"
git -C "$PUSH_REPO" push -q --force "$PUSH_REMOTE" "$DIVERGED_HEAD:refs/heads/main"
printf 'next checkpoint\n' >> "$PUSH_REPO/DEVELOPMENT_STATUS.md"
git -C "$PUSH_REPO" add DEVELOPMENT_STATUS.md
git -C "$PUSH_REPO" commit -q -m 'next checkpoint'
ATOMIC_REJECT_RC=0
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$PUSH_STATE" \
  bash "$PUSH_REPO/scripts/autodevelop/push-checkpoint.sh" > "$TMP/atomic-reject.log" 2>&1 || ATOMIC_REJECT_RC=$?
assert_equal "$ATOMIC_REJECT_RC" 1 'diverged main rejects automatic integration'
assert_equal "$(git --git-dir="$PUSH_REMOTE" rev-parse refs/heads/vale/selftest)" "$PUSH_HEAD" 'atomic rejection leaves recovery branch unchanged'
assert_equal "$(git --git-dir="$PUSH_REMOTE" rev-parse refs/heads/main)" "$DIVERGED_HEAD" 'atomic rejection leaves diverged main unchanged'

OVERRIDE_RC=0
ZIGCSS_AUTODEVELOP_TEST_MODE=0 ZIGCSS_AUTODEVELOP_STATE_DIR="$TMP/forbidden-state" \
  bash -c '. "$1"' _ "$HERE/lib.sh" > /dev/null 2>&1 || OVERRIDE_RC=$?
assert_equal "$OVERRIDE_RC" 1 'external state override rejected outside tests'

mkdir -p "$TMP/state-target"
ln -s "$TMP/state-target" "$TMP/state-link"
SYMLINK_RC=0
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$TMP/state-link" \
  bash -c '. "$1"' _ "$HERE/lib.sh" > /dev/null 2>&1 || SYMLINK_RC=$?
assert_equal "$SYMLINK_RC" 1 'symlink state root rejected'

INTEGER_RC=0
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$TMP/integer-state" \
ZIGCSS_AUTODEVELOP_PASS_TIMEOUT_SECS=invalid \
  bash -c '. "$1"; autodevelop_require_repository' _ "$HERE/lib.sh" > /dev/null 2>&1 || INTEGER_RC=$?
assert_equal "$INTEGER_RC" 1 'invalid numeric configuration rejected'

FAMILY_INTEGER_RC=0
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$TMP/family-integer-state" \
ZIGCSS_AUTODEVELOP_MAX_FAMILY_PASSES=0 \
  bash -c '. "$1"; autodevelop_require_repository' _ "$HERE/lib.sh" > /dev/null 2>&1 || FAMILY_INTEGER_RC=$?
assert_equal "$FAMILY_INTEGER_RC" 1 'zero family convergence threshold rejected'

BATCH_INTEGER_RC=0
ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_STATE_DIR="$TMP/batch-integer-state" \
ZIGCSS_AUTODEVELOP_MAIN_BATCH_PASSES=invalid \
  bash -c '. "$1"; autodevelop_require_repository' _ "$HERE/lib.sh" > /dev/null 2>&1 || BATCH_INTEGER_RC=$?
assert_equal "$BATCH_INTEGER_RC" 1 'invalid main batch threshold rejected'

LOOP_HOME="$TMP/loop-state"
mkdir -p "$LOOP_HOME"
touch "$LOOP_HOME/PAUSE"
ZIGCSS_AUTODEVELOP_STATE_DIR="$LOOP_HOME" ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_IDLE_POLL_SECS=1 \
  bash "$HERE/loop.sh" > "$TMP/loop.log" 2>&1 &
LOOP_PID=$!
READY=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -f "$LOOP_HOME/state/loop.pid" ]; then READY=1; break; fi
  sleep 0.1
done
assert_equal "$READY" 1 'loop becomes ready'
assert_equal "$(cat "$LOOP_HOME/state/loop.pid" 2>/dev/null || true)" "$LOOP_PID" 'loop records owner pid'

SECOND_RC=0
ZIGCSS_AUTODEVELOP_STATE_DIR="$LOOP_HOME" ZIGCSS_AUTODEVELOP_TEST_MODE=1 ZIGCSS_AUTODEVELOP_IDLE_POLL_SECS=1 \
  bash "$HERE/loop.sh" > "$TMP/second-loop.log" 2>&1 || SECOND_RC=$?
assert_equal "$SECOND_RC" 1 'second loop rejected by atomic lock'

touch "$LOOP_HOME/STOP"
rm -f "$LOOP_HOME/PAUSE"
wait "$LOOP_PID"
assert_equal "$(grep '^phase=' "$LOOP_HOME/state/status.txt" | cut -d= -f2)" STOPPED 'graceful stop while idle'

printf 'autodevelop selftest: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
