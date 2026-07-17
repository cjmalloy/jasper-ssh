#!/usr/bin/env bash
set -euo pipefail

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
pass() {
    printf '\033[0;32m[PASS]\033[0m %s\n' "$*"
    summary+=("[PASS] $*")
}
fail() {
    printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2
    summary+=("[FAIL] $*")
    exit 1
}

key_dir=/workspace/ssh_config
state_dir=/workspace/test_state
expected_token=test-token
expected_authorization=$(printf '%s %s' Bearer "$expected_token")
alice_pid=
bob_pid=
summary=()
summary_start_delimiter="=== TEST SUMMARY START ==="
summary_end_delimiter="=== TEST SUMMARY END ==="

cleanup() {
    [ -z "$alice_pid" ] || kill "$alice_pid" 2>/dev/null || true
    [ -z "$bob_pid" ] || kill "$bob_pid" 2>/dev/null || true
}

finish() {
    cleanup
    printf '\n%s\n' "$summary_start_delimiter"
    printf '%s\n' "${summary[@]}"
    printf '%s\n' "$summary_end_delimiter"
}
trap finish EXIT

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ExitOnForwardFailure=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

wait_for_exit() {
    local pid=$1
    local attempts=${2:-10}
    local attempt

    for ((attempt = 0; attempt < attempts; attempt++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    return 1
}

wait_for_file() {
    local path=$1
    local attempts=${2:-10}
    local attempt

    for ((attempt = 0; attempt < attempts; attempt++)); do
        [ -e "$path" ] && return 0
        sleep 1
    done
    return 1
}

assert_header() {
    local response=$1
    local name=$2
    local value=$3

    printf '%s\n' "$response" | grep -Fqx -- "$name: $value" ||
        fail "$name header was not set to $value"
}

assert_proxy_headers() {
    local port=$1
    local user_tag=$2
    local response

    response=$(curl --fail --silent --max-time 2 "http://localhost:$port/")
    assert_header "$response" Authorization "$expected_authorization"
    assert_header "$response" Local-Origin "@test-origin"
    assert_header "$response" Read-Access test-read
    assert_header "$response" Tag-Read-Access test-tag-read
    assert_header "$response" Tag-Write-Access test-tag-write
    assert_header "$response" User-Role test-role
    assert_header "$response" User-Tag "$user_tag"
    assert_header "$response" Write-Access test-write
}

info "Opening tunnels for alice and bob"
ssh "${ssh_options[@]}" -i "$key_dir/alice" -N \
    -L 19001:localhost:38022 alice@target-server &
alice_pid=$!
ssh "${ssh_options[@]}" -i "$key_dir/bob" -N \
    -L 19002:localhost:38023 bob@target-server &
bob_pid=$!

for port in 19001 19002; do
    for _ in {1..10}; do
        curl --fail --silent --max-time 2 "http://localhost:$port/" >/dev/null && break
        sleep 1
    done
    curl --fail --silent --max-time 2 "http://localhost:$port/" >/dev/null ||
        fail "Tunnel on port $port did not proxy the backend"
done
pass "Both users can proxy requests through SSH"

assert_proxy_headers 19001 alice
assert_proxy_headers 19002 bob
pass "Proxy requests include the configured headers for each user"

info "Removing alice's authorized key"
grep -v ' alice$' "$key_dir/authorized_keys" > "$key_dir/authorized_keys.new"
mv "$key_dir/authorized_keys.new" "$key_dir/authorized_keys"

wait_for_exit "$alice_pid" 10 ||
    fail "Alice's existing connection remained open after her key was removed"
alice_pid=
pass "Removing a key closes that user's existing connection"

kill -0 "$bob_pid" 2>/dev/null ||
    fail "Removing alice's key also closed bob's connection"
curl --fail --silent --max-time 2 http://localhost:19002/ >/dev/null ||
    fail "Bob's tunnel stopped proxying after alice's key was removed"
pass "Other users remain connected while shutdown drains"

sleep 3
[ ! -e "$state_dir/unhealthy" ] ||
    fail "Shutdown completed while bob still had an active connection"
pass "Shutdown waits for active SSH connections"

info "Restoring authorized_keys to verify shutdown remains latched"
cp "$key_dir/authorized_keys.original" "$key_dir/authorized_keys"
kill "$bob_pid"
wait "$bob_pid" 2>/dev/null || true
bob_pid=

wait_for_file "$state_dir/unhealthy" 10 ||
    fail "Shutdown was cancelled when authorized_keys was restored"
pass "Shutdown completes after connections drain, even if authorized_keys is restored"
