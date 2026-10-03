#!/usr/bin/env bash
set -eu

pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

script_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$script_dir"
# shellcheck source=../shutdown.sh
. "$script_dir/shutdown.sh"

_tmp_dir=$(mktemp -d)
_log_file="$_tmp_dir/log"
current_keys="$_tmp_dir/current"
observed_keys="$_tmp_dir/observed"
cleanup() { rm -rf "$_tmp_dir"; }
trap cleanup EXIT
touch "$_log_file" "$current_keys" "$observed_keys"

log_message() { printf '%s\n' "$*" >> "$_log_file"; }
assert_log_contains() {
    grep -Fq -- "$1" "$_log_file" ||
        fail "Expected log line not found: '$1' (log: $(cat "$_log_file"))"
}

fetch_api_keys() { return 1; }
normalize_keys() {
    touch "$_tmp_dir/volume-used"
    return 0
}
keys_initialized=false

if apply_key_revocations; then
    fail "API fetch failure should prevent draining"
fi
[ ! -e "$_tmp_dir/volume-used" ] ||
    fail "API fetch failure should not fall back to the mounted volume"
assert_log_contains "shutdown: Kubernetes API key fetch failed; drain mode requires API access"
pass "Drain mode rejects an unavailable API without using the mounted volume"

_test_key_version=1
fetch_api_keys() {
    printf 'ssh-rsa AAAA key%s\n' "$_test_key_version" > "$1"
}
terminate_revoked_user_connections() { :; }
keys_initialized=false
> "$_log_file"
> "$observed_keys"

apply_key_revocations
assert_log_contains "shutdown: initialized API keys (fingerprint: 1 lines, hash="

> "$_log_file"
apply_key_revocations
[ ! -s "$_log_file" ] ||
    fail "Unchanged API keys produced polling logs: $(cat "$_log_file")"

_test_key_version=2
apply_key_revocations
assert_log_contains "shutdown: API keys changed (fingerprint: 1 lines, hash="
pass "Shutdown logs initial and changed fingerprints without unchanged-key polling logs"

kill() { printf '%s\n' "$*" > "$_tmp_dir/kill"; }
restart_immediately
grep -Fqx -- "-TERM 1" "$_tmp_dir/kill" ||
    fail "Restart fallback did not send SIGTERM to PID 1"
assert_log_contains "shutdown: authoritative API keys unavailable; falling back to restart mode"
pass "API failure falls back to restart mode"

apply_key_revocations() { return 1; }
restart_immediately() { touch "$_tmp_dir/restarted"; }
count_ssh_connections() { fail "Connection counting continued after API failure"; }

drain_connections
[ -e "$_tmp_dir/restarted" ] ||
    fail "Initial API failure did not trigger restart fallback"
pass "An initial API failure aborts draining"

_apply_count=0
apply_key_revocations() {
    _apply_count=$((_apply_count + 1))
    [ "$_apply_count" -eq 1 ]
}
restart_immediately() { touch "$_tmp_dir/restarted-during-drain"; }
count_ssh_connections() { printf '1\n'; }
sleep() { :; }

drain_connections
[ "$_apply_count" -eq 2 ] ||
    fail "Expected two API checks, got $_apply_count"
[ -e "$_tmp_dir/restarted-during-drain" ] ||
    fail "API failure during draining did not trigger restart fallback"
pass "An API failure during draining aborts to restart mode"
