#!/bin/sh
# shellcheck shell=ash

find_sshd_listener() {
    local fd
    local inode
    local socket

    for inode in $(awk '
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

connection_count=$(count_ssh_connections) || exit 1
if [ "$connection_count" -gt 0 ]; then
    echo "Draining $connection_count SSH connection(s)."
fi
while [ "$connection_count" -gt 0 ]; do
    sleep 5
    connection_count=$(count_ssh_connections) || exit 1
done

echo "All SSH connections drained."
