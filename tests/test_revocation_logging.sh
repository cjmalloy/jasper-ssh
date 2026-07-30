#!/usr/bin/env bash
# Unit tests for signal_user_connections() logging in key-revocation.sh.
# Run directly: bash tests/test_revocation_logging.sh
#
# Note: pipefail is intentionally omitted; key-revocation.sh is designed for
# ash/sh where pipefail is not set, and pgrep may return non-zero when no
# processes match.
set -eu

pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

script_dir=$(cd "$(dirname "$0")/.." && pwd)

# ---------------------------------------------------------------------------
# Source key-revocation.sh to load signal_user_connections() and friends.
# Mocks are defined AFTER sourcing so they override the sourced definitions.
#
# signal_user_connections() pipes pgrep output into a while-read loop, which
# bash runs in a subshell.  Functions must be export -f'd so the subshell
# can call them, and log output is captured to a temp file rather than a
# variable so it survives the subshell boundary.
# ---------------------------------------------------------------------------

# shellcheck source=../key-revocation.sh
. "$script_dir/key-revocation.sh"

_log_file=$(mktemp)
cleanup() { rm -f "$_log_file" "${_kill_call_count_file:-}"; }
trap cleanup EXIT

# Redirect log output to a file accessible from subshells.
log_message() { printf '%s\n' "$*" >> "$_log_file"; }
export -f log_message
export _log_file

reset_log() { > "$_log_file"; }
assert_log_contains() {
    grep -Fq -- "$1" "$_log_file" ||
        fail "Expected log line not found: '$1' (log: $(cat "$_log_file"))"
}
assert_log_not_contains() {
    if grep -Fq -- "$1" "$_log_file" 2>/dev/null; then
        fail "Unexpected log line found: '$1' (log: $(cat "$_log_file"))"
    fi
}
assert_log_count() {
    local pattern=$1 expected=$2 actual
    actual=$(grep -cF -- "$pattern" "$_log_file" || true)
    [ "$actual" = "$expected" ] ||
        fail "Expected $expected occurrence(s) of '$pattern', found $actual (log: $(cat "$_log_file"))"
}

# ---------------------------------------------------------------------------
# Test 1 – successful kill logs "Sent SIG…"
# ---------------------------------------------------------------------------

pgrep() { printf '99901\n'; }
kill() { return 0; }
export -f pgrep kill

reset_log
signal_user_connections TERM alice

assert_log_contains "Sent SIGTERM to sshd session for alice (PID 99901)."
assert_log_contains "Sent SIGTERM to sshd-session session for alice (PID 99901)."
assert_log_not_contains "Could not send"
pass "Successful kill logs 'Sent SIG\${signal}' for each matched process"

# ---------------------------------------------------------------------------
# Test 2 – failed kill logs "Could not send SIG…"
# ---------------------------------------------------------------------------

kill() { return 1; }
export -f kill

reset_log
signal_user_connections KILL bob

assert_log_contains "Could not send SIGKILL to sshd session for bob (PID 99901); it may have already exited."
assert_log_contains "Could not send SIGKILL to sshd-session session for bob (PID 99901); it may have already exited."
assert_log_not_contains "Sent SIG"
pass "Failed kill logs 'Could not send SIG\${signal}' for each matched process"

# ---------------------------------------------------------------------------
# Test 3 – no matching processes produces no log output
# ---------------------------------------------------------------------------

pgrep() { return 1; }
kill() { return 0; }
export -f pgrep kill

reset_log
signal_user_connections TERM nobody

[ ! -s "$_log_file" ] ||
    fail "Expected no log output when no processes match, got: $(cat "$_log_file")"
pass "No matching processes produces no log output"

# ---------------------------------------------------------------------------
# Test 4 – a failed kill does not abort processing (remaining PIDs are tried)
# ---------------------------------------------------------------------------

_kill_call_count_file=$(mktemp)
export _kill_call_count_file

pgrep() { printf '11111\n12222\n'; }
kill() {
    local n
    n=$(cat "$_kill_call_count_file")
    echo $((n + 1)) > "$_kill_call_count_file"
    # Fail on the first call within each process_name loop (odd calls),
    # succeed on the second (even calls).
    [ $(( (n + 1) % 2 )) -eq 0 ]
}
export -f pgrep kill

echo 0 > "$_kill_call_count_file"
reset_log
signal_user_connections TERM alice

# pgrep is called once per process_name (sshd, sshd-session).
# kill sequence: fail(11111), succeed(12222), fail(11111), succeed(12222).
assert_log_count "Sent SIGTERM" 2
assert_log_count "Could not send SIGTERM" 2
pass "A failed kill does not abort processing; remaining PIDs are still signalled"
