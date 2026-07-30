#!/bin/sh
# shellcheck shell=ash

# shellcheck source=key-revocation.sh
if [ -r /key-revocation.sh ]; then
    . /key-revocation.sh
else
    . ./key-revocation.sh
fi

apply_key_revocations() {
    local fp

    if ! fetch_api_keys "$current_keys"; then
        log_message "shutdown: Kubernetes API key fetch failed; drain mode requires API access"
        return 1
    fi

    fp=$(key_file_fingerprint "$current_keys")
    if [ "$keys_initialized" = false ] ||
        ! cmp -s "$observed_keys" "$current_keys"; then
        if [ "$keys_initialized" = true ]; then
            log_message "shutdown: keys changed [API] (fingerprint: ${fp})"
        else
            log_message "shutdown: initial keys [API] (fingerprint: ${fp})"
        fi
        terminate_revoked_user_connections "$current_keys"
        cp "$current_keys" "$observed_keys" || return 1
        keys_initialized=true
    else
        log_message "shutdown: keys unchanged [API] (fingerprint: ${fp})"
    fi
}

restart_immediately() {
    log_message "shutdown: authoritative API keys unavailable; falling back to restart mode"
    if ! kill -TERM 1 2>/dev/null; then
        log_message "shutdown: could not signal PID 1 for restart"
        return 1
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

drain_connections() {
    if ! apply_key_revocations; then
        restart_immediately
        return $?
    fi

    connection_count=$(count_ssh_connections) || return 1
    log_message "shutdown: initial SSH connection count: ${connection_count}"
    if [ "$connection_count" -gt 0 ]; then
        echo "Draining $connection_count SSH connection(s)."
    fi
    _sd_iter=0
    _sd_prev=$connection_count
    while [ "$connection_count" -gt 0 ]; do
        sleep 5
        _sd_iter=$((_sd_iter + 1))
        if ! apply_key_revocations; then
            restart_immediately
            return $?
        fi
        _sd_prev=$connection_count
        connection_count=$(count_ssh_connections) || return 1
        if [ "$connection_count" -ne "$_sd_prev" ]; then
            log_message "shutdown: connection count changed: ${_sd_prev} -> ${connection_count}"
        else
            log_message "shutdown: poll ${_sd_iter}: ${connection_count} SSH connection(s) remaining"
        fi
    done

    echo "All SSH connections drained."
}

shutdown_main() {
    current_keys=$(mktemp) || return 1
    observed_keys=$(mktemp) || {
        rm -f "$current_keys"
        return 1
    }
    keys_initialized=false
    sshd_stopped=false
    trap 'rm -f "$current_keys" "$observed_keys"' EXIT
    trap 'stop_accepting_connections' INT TERM
    log_message "shutdown: initializing"
    stop_accepting_connections
    drain_connections
}

if [ "${0##*/}" = shutdown.sh ]; then
    shutdown_main "$@"
fi
