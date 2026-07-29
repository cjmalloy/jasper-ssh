#!/bin/sh
# shellcheck shell=ash

# shellcheck source=key-revocation.sh
. /key-revocation.sh

apply_key_revocations() {
    [ -e /config/authorized_keys ] || return 0
    normalize_keys /config/authorized_keys "$current_keys" || return 1
    if [ "$keys_initialized" = false ] ||
        ! cmp -s "$observed_keys" "$current_keys"; then
        terminate_revoked_user_connections "$current_keys"
        cp "$current_keys" "$observed_keys" || return 1
        keys_initialized=true
    fi
}

find_sshd_listener() {
    local fd
    local inode
    local socket

    for inode in $(awk '
        # 0016 is SSH port 22; 0A is TCP_LISTEN.
        $2 ~ /:0016$/ && $4 == "0A" { print $10 }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null); do
        socket="socket:[$inode]"
        for fd in /proc/[0-9]*/fd/*; do
            [ "$(readlink "$fd" 2>/dev/null)" = "$socket" ] || continue
            printf '%s\n' "${fd#/proc/}" | cut -d/ -f1
            return 0
        done
    done
    return 1
}

count_ssh_connections() {
    awk '
        # 0016 is SSH port 22; 01 is TCP_ESTABLISHED.
        $2 ~ /:0016$/ && $4 == "01" { count++ }
        END { print count + 0 }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

stop_accepting_connections() {
    local listener_pid

    [ "$sshd_stopped" = false ] || return
    sshd_stopped=true
    listener_pid=$(find_sshd_listener) || return
    echo "Stopping SSH listener (PID $listener_pid)."
    kill -TERM "$listener_pid" 2>/dev/null || true
}

current_keys=$(mktemp) || exit 1
observed_keys=$(mktemp) || {
    rm -f "$current_keys"
    exit 1
}
keys_initialized=false
sshd_stopped=false
trap 'rm -f "$current_keys" "$observed_keys"' EXIT
trap 'stop_accepting_connections' INT TERM
stop_accepting_connections

apply_key_revocations ||
    echo "Could not apply authorized-key revocations; continuing shutdown drain." >&2
connection_count=$(count_ssh_connections) || exit 1
if [ "$connection_count" -gt 0 ]; then
    echo "Draining $connection_count SSH connection(s)."
fi
while [ "$connection_count" -gt 0 ]; do
    sleep 5
    apply_key_revocations ||
        echo "Could not apply authorized-key revocations; continuing shutdown drain." >&2
    connection_count=$(count_ssh_connections) || exit 1
done

echo "All SSH connections drained."
