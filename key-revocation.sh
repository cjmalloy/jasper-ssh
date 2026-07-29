#!/bin/sh
# shellcheck shell=ash

log_message() {
    printf '%s\n' "$*"
    [ ! -w /proc/1/fd/1 ] || printf '%s\n' "$*" > /proc/1/fd/1
}

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
                if kill "-$signal" "$pid" 2>/dev/null; then
                    log_message "Sent SIG${signal} to ${process_name} session for ${user} (PID ${pid})."
                else
                    log_message "Could not send SIG${signal} to ${process_name} session for ${user} (PID ${pid}); it may have already exited."
                fi
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
    local current_keys="$1"
    local revoked_users=
    local user_keys
    local user

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=$(user_from_keys_path "$user_keys")
        user_has_revoked_key "$user_keys" "$current_keys" || continue

        log_message "An authorized key for $user was removed; terminating their SSH connections."
        revoked_users="$revoked_users $user"
    done

    signal_users TERM "$revoked_users"
    [ -z "$revoked_users" ] || sleep 1
    signal_users KILL "$revoked_users"
}
