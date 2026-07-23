#!/bin/sh
# shellcheck shell=ash

CONFIG_CHANGE_MODE=${CONFIG_CHANGE_MODE:-restart}
NORMALIZED_KEYS=/tmp/authorized_keys.normalized
SHUTDOWN_LATCH=/tmp/authorized_keys_shutdown
REVOCATION_LOCK=/tmp/authorized_keys_revocation_started

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
    local current_keys="$1"
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

remove_configured_users() {
    local user_keys
    local user

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=$(user_from_keys_path "$user_keys")

        echo "Removing configuration for $user before restart."
        rm -f "/etc/nginx/conf.d/$user.conf"
        if awk -F: -v user="$user" '$1 == user { found = 1 } END { exit !found }' \
            /etc/passwd && ! deluser "$user"; then
            echo "Could not remove user $user; restart aborted." >&2
            return 1
        fi
        rm -rf "/home/${user:?}"
    done
}

service_check() {
    if ! pgrep "$1" > /dev/null; then
        echo "$1 is not running."
        exit 1
    fi
}

record_key_change() {
    local current_keys="$1"

    touch "$SHUTDOWN_LATCH"
    if mkdir "$REVOCATION_LOCK" 2>/dev/null; then
        if ! cmp -s "$NORMALIZED_KEYS" "$current_keys"; then
            terminate_revoked_user_connections "$current_keys"
            cp "$current_keys" "$NORMALIZED_KEYS"
        fi
        rmdir "$REVOCATION_LOCK"
    fi
}

count_ssh_connections() {
    awk '
        $2 ~ /:0016$/ && $4 == "01" { count++ }
        END { print count + 0 }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

handle_latched_shutdown() {
    local connection_count

    case "$CONFIG_CHANGE_MODE" in
        restart)
            echo "The /config/authorized_keys file has been modified."
            remove_configured_users || exit 1
            kill -TERM 1
            exit 1
            ;;
        drain) ;;
        *)
            echo "CONFIG_CHANGE_MODE must be restart or drain."
            kill -TERM 1
            exit 1
            ;;
    esac

    connection_count=$(count_ssh_connections)
    if [ "$connection_count" -eq 0 ]; then
        echo "The /config/authorized_keys file has been modified."
        kill -TERM 1
        exit 1
    fi
    echo "The /config/authorized_keys file has been modified; draining $connection_count SSH connection(s)."
    exit 0
}

service_check sshd
service_check nginx

if [ -e "$NORMALIZED_KEYS" ] && [ -e /config/authorized_keys ]; then
    current_keys=$(mktemp)
    trap 'rm -f "$current_keys"' EXIT
    if normalize_keys /config/authorized_keys "$current_keys" &&
        ! cmp -s "$NORMALIZED_KEYS" "$current_keys"; then
        record_key_change "$current_keys"
    fi
    [ ! -e "$SHUTDOWN_LATCH" ] || handle_latched_shutdown
fi

echo "SSH and Nginx are running, and /config/authorized_keys is unchanged."
exit 0
