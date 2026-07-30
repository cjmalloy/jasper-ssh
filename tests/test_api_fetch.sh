#!/usr/bin/env bash
# Unit tests for fetch_api_keys() in key-revocation.sh.
# Run directly: bash tests/test_api_fetch.sh
set -eu

pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

script_dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../key-revocation.sh
. "$script_dir/key-revocation.sh"

_log_file=$(mktemp)
_sa_dir=$(mktemp -d)
_out=$(mktemp)
cleanup() { rm -f "$_log_file" "$_out"; rm -rf "$_sa_dir"; }
trap cleanup EXIT

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

# Set up mock service-account directory.
printf '%s' 'mock-sa-token' > "$_sa_dir/token"
touch "$_sa_dir/ca.crt"
printf '%s' 'test-ns' > "$_sa_dir/namespace"

AUTHORIZED_KEYS_CONFIGMAP_NAME="jasper-authorized-keys"
NAMESPACE="test-ns"
export AUTHORIZED_KEYS_CONFIGMAP_NAME NAMESPACE

# JSON body returned by the mock API containing two authorized keys.
# \n sequences inside the string value represent key line separators.
_mock_json='{"kind":"ConfigMap","apiVersion":"v1","data":{"authorized_keys":"ssh-ed25519 AAAA key1\\nssh-rsa BBBB key2\\n"}}'

# ---------------------------------------------------------------------------
# Helper: mock curl that writes $_mock_json to -o file and prints HTTP status.
# ---------------------------------------------------------------------------
mock_curl_200() {
    local write_next=false o_file=""
    for arg in "$@"; do
        if [ "$write_next" = true ]; then
            o_file="$arg"; write_next=false
        elif [ "$arg" = "-o" ]; then
            write_next=true
        fi
    done
    [ -n "$o_file" ] && printf '%s' "$_mock_json" > "$o_file"
    printf '200'
}
export -f mock_curl_200
export _mock_json

# ---------------------------------------------------------------------------
# Test 1 - successful fetch writes normalized keys to the output file
# ---------------------------------------------------------------------------

curl() { mock_curl_200 "$@"; }
export -f curl

reset_log
> "$_out"
fetch_api_keys "$_out" "$_sa_dir"

[ -s "$_out" ] || fail "output file should be non-empty after successful fetch"
grep -Fq "ssh-ed25519 AAAA key1" "$_out" ||
    fail "output should contain first key"
grep -Fq "ssh-rsa BBBB key2" "$_out" ||
    fail "output should contain second key"
assert_log_contains "key-revocation: fetched keys from API (test-ns/jasper-authorized-keys)"
pass "API fetch success: normalized keys written to output file and fetch logged"

# NAMESPACE is optional when the service-account namespace file is available.
unset NAMESPACE
reset_log
> "$_out"
fetch_api_keys "$_out" "$_sa_dir"
assert_log_contains "key-revocation: fetched keys from API (test-ns/jasper-authorized-keys)"
pass "API fetch uses the service-account namespace when NAMESPACE is unset"
NAMESPACE="test-ns"
export NAMESPACE

# ---------------------------------------------------------------------------
# Test 2 - non-200 HTTP status returns 1 and logs failure
# ---------------------------------------------------------------------------

curl() {
    local write_next=false o_file=""
    for arg in "$@"; do
        if [ "$write_next" = true ]; then o_file="$arg"; write_next=false
        elif [ "$arg" = "-o" ]; then write_next=true
        fi
    done
    [ -n "$o_file" ] && printf '{"message":"Forbidden"}' > "$o_file"
    printf '403'
}
export -f curl

reset_log
> "$_out"
if fetch_api_keys "$_out" "$_sa_dir"; then
    fail "expected non-zero exit for HTTP 403"
fi
assert_log_contains "key-revocation: API fetch failed (HTTP 403)"
pass "Non-200 HTTP status returns failure and logs the status code"

# ---------------------------------------------------------------------------
# Test 3 - curl connection failure (exits non-zero) returns 1 and logs failure
# ---------------------------------------------------------------------------

curl() {
    local write_next=false o_file=""
    for arg in "$@"; do
        if [ "$write_next" = true ]; then o_file="$arg"; write_next=false
        elif [ "$arg" = "-o" ]; then write_next=true
        fi
    done
    [ -n "$o_file" ] && : > "$o_file"
    return 1
}
export -f curl

reset_log
> "$_out"
if fetch_api_keys "$_out" "$_sa_dir"; then
    fail "expected non-zero exit when curl fails"
fi
assert_log_contains "key-revocation: API fetch failed (HTTP failed)"
pass "Curl connection failure returns non-zero and logs it"

# ---------------------------------------------------------------------------
# Test 4 - missing AUTHORIZED_KEYS_CONFIGMAP_NAME returns 1 with a clear log
# ---------------------------------------------------------------------------

unset AUTHORIZED_KEYS_CONFIGMAP_NAME

reset_log
if fetch_api_keys "$_out" "$_sa_dir"; then
    fail "expected non-zero exit when configmap name not set"
fi
assert_log_contains "key-revocation: AUTHORIZED_KEYS_CONFIGMAP_NAME is not set; cannot fetch API keys"
pass "Missing AUTHORIZED_KEYS_CONFIGMAP_NAME returns failure with a clear log"
AUTHORIZED_KEYS_CONFIGMAP_NAME="jasper-authorized-keys"
export AUTHORIZED_KEYS_CONFIGMAP_NAME

# ---------------------------------------------------------------------------
# Test 5 - response with no authorized_keys data returns 1 and logs it
# ---------------------------------------------------------------------------

curl() {
    local write_next=false o_file=""
    for arg in "$@"; do
        if [ "$write_next" = true ]; then o_file="$arg"; write_next=false
        elif [ "$arg" = "-o" ]; then write_next=true
        fi
    done
    [ -n "$o_file" ] && printf '{"kind":"ConfigMap","data":{}}' > "$o_file"
    printf '200'
}
export -f curl

reset_log
> "$_out"
if fetch_api_keys "$_out" "$_sa_dir"; then
    fail "expected non-zero exit when authorized_keys field is absent"
fi
assert_log_contains "key-revocation: API response contained no authorized_keys field"
pass "Missing authorized_keys field in response returns failure and logs it"
