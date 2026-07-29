#!/bin/sh
# shellcheck shell=ash

CONFIG_CHANGE_MODE=${CONFIG_CHANGE_MODE:-restart}
NORMALIZED_KEYS=/tmp/authorized_keys.normalized
SHUTDOWN_LATCH=/tmp/authorized_keys_shutdown
REVOCATION_LOCK=/tmp/authorized_keys_revocation_started

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

remove_configured_users() {
    local user_keys
    local user

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=$(user_from_keys_path "$user_keys")

        log_message "Removing configuration for $user before restart."
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
    log_message "Authorized key change detected; shutdown latched in ${CONFIG_CHANGE_MODE:-restart} mode."
    if mkdir "$REVOCATION_LOCK" 2>/dev/null; then
        if ! cmp -s "$NORMALIZED_KEYS" "$current_keys"; then
            cp "$current_keys" "$NORMALIZED_KEYS"
        fi
        rmdir "$REVOCATION_LOCK"
    fi
}

handle_latched_shutdown() {
    case "$CONFIG_CHANGE_MODE" in
        restart)
            log_message "Shutdown latch active; restarting immediately."
            remove_configured_users || exit 1
            kill -TERM 1
            exit 1
            ;;
        drain) return 0 ;;
        *)
            echo "CONFIG_CHANGE_MODE must be restart or drain."
            kill -TERM 1
            exit 1
            ;;
    esac
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

echo "SSH and Nginx are running."
exit 0
