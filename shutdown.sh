#!/bin/sh
# shellcheck shell=ash

# shellcheck source=key-revocation.sh
. /key-revocation.sh

apply_key_revocations() {
    if [ ! -e /config/authorized_keys ]; then
        log_message "shutdown: /config/authorized_keys: not found; skipping revocations"
        return 0
    fi
    log_path_metadata "shutdown:" /config/authorized_keys
    normalize_keys /config/authorized_keys "$current_keys" || return 1
    local fp
    fp=$(key_file_fingerprint "$current_keys")
    if [ "$keys_initialized" = false ] ||
        ! cmp -s "$observed_keys" "$current_keys"; then
        if [ "$keys_initialized" = true ]; then
            log_message "shutdown: keys changed (fingerprint: ${fp})"
        else
            log_message "shutdown: initial keys fingerprint: ${fp}"
        fi
        terminate_revoked_user_connections "$current_keys"
        cp "$current_keys" "$observed_keys" || return 1
        keys_initialized=true
    else
        log_message "shutdown: keys unchanged (fingerprint: ${fp})"
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
log_message "shutdown: initializing"
stop_accepting_connections

apply_key_revocations ||
    echo "Could not apply authorized-key revocations; continuing shutdown drain." >&2
connection_count=$(count_ssh_connections) || exit 1
log_message "shutdown: initial SSH connection count: ${connection_count}"
if [ "$connection_count" -gt 0 ]; then
    echo "Draining $connection_count SSH connection(s)."
fi
_sd_iter=0
_sd_prev=$connection_count
while [ "$connection_count" -gt 0 ]; do
    sleep 5
    _sd_iter=$((_sd_iter + 1))
    apply_key_revocations ||
        echo "Could not apply authorized-key revocations; continuing shutdown drain." >&2
    _sd_prev=$connection_count
    connection_count=$(count_ssh_connections) || exit 1
    if [ "$connection_count" -ne "$_sd_prev" ]; then
        log_message "shutdown: connection count changed: ${_sd_prev} -> ${connection_count}"
    else
        log_message "shutdown: poll ${_sd_iter}: ${connection_count} SSH connection(s) remaining"
    fi
done

echo "All SSH connections drained."
