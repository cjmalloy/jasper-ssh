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
alice_second_pid=
bob_pid=
charlie_pid=
drain_alice_pid=
drain_bob_pid=
unauthorized_pid=
summary=()
summary_start_delimiter="=== TEST SUMMARY START ==="
summary_end_delimiter="=== TEST SUMMARY END ==="

cleanup() {
    [ -z "$alice_pid" ] || kill "$alice_pid" 2>/dev/null || true
    [ -z "$alice_second_pid" ] || kill "$alice_second_pid" 2>/dev/null || true
    [ -z "$bob_pid" ] || kill "$bob_pid" 2>/dev/null || true
    [ -z "$charlie_pid" ] || kill "$charlie_pid" 2>/dev/null || true
    [ -z "$drain_alice_pid" ] || kill "$drain_alice_pid" 2>/dev/null || true
    [ -z "$drain_bob_pid" ] || kill "$drain_bob_pid" 2>/dev/null || true
    [ -z "$unauthorized_pid" ] || kill "$unauthorized_pid" 2>/dev/null || true
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
    local origin=${3:-@test-origin}
    local response

    response=$(curl --fail --silent --max-time 2 "http://localhost:$port/")
    assert_header "$response" Authorization "$expected_authorization"
    assert_header "$response" Local-Origin "$origin"
    assert_header "$response" Read-Access test-read
    assert_header "$response" Tag-Read-Access test-tag-read
    assert_header "$response" Tag-Write-Access test-tag-write
    assert_header "$response" User-Role test-role
    assert_header "$response" User-Tag "$user_tag"
    assert_header "$response" Write-Access test-write
}

[ -e "$state_dir/config-tested" ] ||
    fail "Missing configuration checks did not complete"
[ ! -e "$state_dir/config-error" ] ||
    fail "$(cat "$state_dir/config-error")"
pass "Missing required configuration produces clear startup failures"

info "Opening tunnels for test users"
ssh "${ssh_options[@]}" -i "$key_dir/alice" -N \
    -L 19001:localhost:38022 alice@target-server &
alice_pid=$!
ssh "${ssh_options[@]}" -i "$key_dir/alice_second" -N \
    -L 19004:localhost:38022 alice@target-server &
alice_second_pid=$!
ssh "${ssh_options[@]}" -i "$key_dir/bob" -N \
    -L 19002:localhost:38023 bob@target-server &
bob_pid=$!
ssh "${ssh_options[@]}" -i "$key_dir/charlie" -N \
    -L 19003:localhost:38024 custom-origin_charlie@target-server &
charlie_pid=$!
ssh "${ssh_options[@]}" -i "$key_dir/alice" -N \
    -L 19101:localhost:38022 alice@target-server-drain &
drain_alice_pid=$!
ssh "${ssh_options[@]}" -i "$key_dir/bob" -N \
    -L 19102:localhost:38023 bob@target-server-drain &
drain_bob_pid=$!

for port in 19001 19002 19003 19004 19101 19102; do
    for _ in {1..10}; do
        curl --fail --silent --max-time 2 "http://localhost:$port/" >/dev/null && break
        sleep 1
    done
    curl --fail --silent --max-time 2 "http://localhost:$port/" >/dev/null ||
        fail "Tunnel on port $port did not proxy the backend"
done
pass "All users and multiple keys for one user can proxy requests"

assert_proxy_headers 19001 alice
assert_proxy_headers 19002 bob
assert_proxy_headers 19003 charlie "@custom-origin"
pass "Proxy requests include configured and key-comment override headers"

websocket_response=$(
    curl --fail --silent --max-time 2 \
        -H "Connection: Upgrade" -H "Upgrade: websocket" \
        http://localhost:19001/
)
assert_header "$websocket_response" Connection upgrade
assert_header "$websocket_response" Upgrade websocket
pass "WebSocket upgrade headers pass through the proxy"

info "Reordering authorized keys"
awk '{ keys[NR] = $0 } END { for (line = NR; line > 0; line--) print keys[line] }' \
    "$key_dir/authorized_keys" > "$key_dir/authorized_keys.new"
mv "$key_dir/authorized_keys.new" "$key_dir/authorized_keys"
sleep 3

for pid in "$alice_pid" "$alice_second_pid" "$bob_pid" "$charlie_pid" \
    "$drain_alice_pid" "$drain_bob_pid"; do
    kill -0 "$pid" 2>/dev/null ||
        fail "Reordering authorized keys closed an existing connection"
done
for port in 19001 19002 19003 19004 19101 19102; do
    curl --fail --silent --max-time 2 "http://localhost:$port/" >/dev/null ||
        fail "Reordering authorized keys stopped an existing tunnel"
done
pass "Reordering authorized keys does not revoke any users"

info "Trying to forward alice to bob's upstream port"
ssh "${ssh_options[@]}" -i "$key_dir/alice" -N \
    -L 19005:localhost:38023 alice@target-server &
unauthorized_pid=$!
sleep 1
if curl --fail --silent --max-time 2 http://localhost:19005/ >/dev/null; then
    fail "Alice could forward to bob's unauthorized port"
fi
kill "$unauthorized_pid" 2>/dev/null || true
wait "$unauthorized_pid" 2>/dev/null || true
unauthorized_pid=
pass "SSH rejects forwarding to unauthorized ports"

info "Removing one of alice's authorized keys"
grep -Fvx -- "$(cat "$key_dir/alice_second.pub")" \
    "$key_dir/authorized_keys" > "$key_dir/authorized_keys.new"
mv "$key_dir/authorized_keys.new" "$key_dir/authorized_keys"

wait_for_exit "$alice_pid" 10 ||
    fail "Alice's first connection remained open after her second key was removed"
wait_for_exit "$alice_second_pid" 10 ||
    fail "Alice's second connection remained open after its key was removed"
wait_for_exit "$drain_alice_pid" 10 ||
    fail "Alice's drain-mode connection remained open after her key was removed"
alice_pid=
alice_second_pid=
drain_alice_pid=
pass "Revoking one of multiple keys closes all sessions for that user"

kill -0 "$bob_pid" 2>/dev/null ||
    fail "Removing alice's key also closed bob's connection"
kill -0 "$charlie_pid" 2>/dev/null ||
    fail "Removing alice's key also closed charlie's connection"
curl --fail --silent --max-time 2 http://localhost:19002/ >/dev/null ||
    fail "Bob's tunnel stopped proxying after alice's key was removed"
curl --fail --silent --max-time 2 http://localhost:19102/ >/dev/null ||
    fail "Drain mode stopped bob's authorized session"
pass "Other users remain connected while shutdown drains"

ssh "${ssh_options[@]}" -i "$key_dir/bob" -N \
    -L 19103:localhost:38023 bob@target-server-drain &
unauthorized_pid=$!
sleep 2
if curl --fail --silent --max-time 2 http://localhost:19103/ >/dev/null; then
    fail "Drain mode accepted a new SSH connection"
fi
kill "$unauthorized_pid" 2>/dev/null || true
wait "$unauthorized_pid" 2>/dev/null || true
unauthorized_pid=
pass "Drain mode becomes unavailable while preserving authorized sessions"

info "Restoring authorized_keys to verify shutdown remains latched"
cp "$key_dir/authorized_keys.original" "$key_dir/authorized_keys"
shutdown_started=$SECONDS
kill "$bob_pid"
wait "$bob_pid" 2>/dev/null || true
bob_pid=
kill "$charlie_pid"
wait "$charlie_pid" 2>/dev/null || true
charlie_pid=

ssh "${ssh_options[@]}" -o ConnectionAttempts=20 -i "$key_dir/bob" -N \
    -L 19006:localhost:38023 bob@target-server &
bob_pid=$!
for _ in {1..20}; do
    curl --fail --silent --max-time 2 http://localhost:19006/ >/dev/null && break
    sleep 1
done
curl --fail --silent --max-time 2 http://localhost:19006/ >/dev/null ||
    fail "Restart mode did not accept connections after sessions drained"
shutdown_elapsed=$((SECONDS - shutdown_started))
[ "$shutdown_elapsed" -le 20 ] ||
    fail "Restart mode took too long to return"
pass "Restart mode exits and restarts after connections drain"

curl --fail --silent --max-time 2 http://localhost:19102/ >/dev/null ||
    fail "Restoring authorized_keys cancelled drain mode"
pass "Drain mode remains latched after authorized_keys is restored"
