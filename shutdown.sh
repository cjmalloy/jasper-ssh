#!/bin/sh
# shellcheck shell=ash

find_sshd_listener() {
    local status
    local name
    local parent_pid

    for status in /proc/[0-9]*/status; do
        [ -r "$status" ] || continue
        name=$(awk '$1 == "Name:" { print $2 }' "$status")
        [ "$name" = sshd ] || continue
        parent_pid=$(awk '$1 == "PPid:" { print $2 }' "$status")
        [ "$parent_pid" -eq 1 ] || continue

        printf '%s\n' "${status#/proc/}" | cut -d/ -f1
        return 0
    done
    return 1
}

count_ssh_connections() {
    awk '
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

sshd_stopped=false
trap 'stop_accepting_connections' INT TERM
stop_accepting_connections

while connection_count=$(count_ssh_connections) &&
    [ "$connection_count" -gt 0 ]; do
    echo "Draining $connection_count SSH connection(s)."
    sleep 1
done

[ "${connection_count:-0}" -eq 0 ] || exit 1
echo "All SSH connections drained."
