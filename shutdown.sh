#!/bin/sh
# shellcheck shell=ash

normalize_keys() {
    sed 's/^[	 ]*//;s/[	 ]*$//;/^[	 ]*#/d;/^$/d' "$1" |
        LC_ALL=C sort -u > "$2"
}

user_from_keys_path() {
    local configured_user="${1#/home/}"
    printf '%s\n' "${configured_user%%/*}"
}

user_has_revoked_key() {
    local user_keys="$1"
    local current_keys="$2"
    local key

    while IFS= read -r key; do
        grep -Fqx -- "$key" "$current_keys" || return 0
    done < "$user_keys"
    return 1
}

signal_user_connections() {
    local signal="$1"
    local user="$2"
    local escaped_user
    local process_name
    local pid
    escaped_user=$(printf '%s' "$user" | sed 's/[][\\.^$*+?{}|()]/\\&/g')

    for process_name in sshd sshd-session; do
        pgrep -f "^${process_name}: ${escaped_user}([ @]|$)" 2>/dev/null |
            while IFS= read -r pid; do
                kill "-$signal" "$pid" 2>/dev/null || true
            done
    done
}

signal_users() {
    local signal="$1"
    local users="$2"
    local user

    for user in $users; do
        signal_user_connections "$signal" "$user"
    done
}

terminate_revoked_user_connections() {
    local revoked_users=
    local user_keys
    local user

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=$(user_from_keys_path "$user_keys")
        user_has_revoked_key "$user_keys" "$current_keys" || continue

        echo "An authorized key for $user was removed; terminating their SSH connections."
        revoked_users="$revoked_users $user"
    done

    signal_users TERM "$revoked_users"
    [ -z "$revoked_users" ] || sleep 1
    signal_users KILL "$revoked_users"
}

apply_key_revocations() {
    [ -e /config/authorized_keys ] || return 0
    normalize_keys /config/authorized_keys "$current_keys" || return 1
    if [ "$keys_initialized" = false ] ||
        ! cmp -s "$observed_keys" "$current_keys"; then
        terminate_revoked_user_connections
        cp "$current_keys" "$observed_keys"
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

apply_key_revocations || exit 1
connection_count=$(count_ssh_connections) || exit 1
if [ "$connection_count" -gt 0 ]; then
    echo "Draining $connection_count SSH connection(s)."
fi
while [ "$connection_count" -gt 0 ]; do
    sleep 5
    apply_key_revocations || exit 1
    connection_count=$(count_ssh_connections) || exit 1
done

echo "All SSH connections drained."
