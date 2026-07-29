#!/bin/sh
# shellcheck shell=ash

# shellcheck source=key-revocation.sh
. /key-revocation.sh

CONFIG_CHANGE_MODE=${CONFIG_CHANGE_MODE:-restart}
NORMALIZED_KEYS=/tmp/authorized_keys.normalized
SHUTDOWN_LATCH=/tmp/authorized_keys_shutdown
REVOCATION_LOCK=/tmp/authorized_keys_revocation_started

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
    log_message "healthcheck: semantic key change detected; shutdown latched in ${CONFIG_CHANGE_MODE:-restart} mode."
    if mkdir "$REVOCATION_LOCK" 2>/dev/null; then
        log_message "healthcheck: acquired revocation lock"
        if ! cmp -s "$NORMALIZED_KEYS" "$current_keys"; then
            terminate_revoked_user_connections "$current_keys"
            cp "$current_keys" "$NORMALIZED_KEYS"
        else
            log_message "healthcheck: keys already up to date (concurrent update); skipping revocations"
        fi
        rmdir "$REVOCATION_LOCK"
    else
        log_message "healthcheck: revocation already in progress; skipping"
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
    log_path_metadata "healthcheck:" /config/authorized_keys
    current_keys=$(mktemp)
    trap 'rm -f "$current_keys"' EXIT
    if normalize_keys /config/authorized_keys "$current_keys"; then
        _hc_fp=$(key_file_fingerprint "$current_keys")
        log_message "healthcheck: current keys fingerprint: ${_hc_fp}"
        if ! cmp -s "$NORMALIZED_KEYS" "$current_keys"; then
            record_key_change "$current_keys"
        else
            log_message "healthcheck: keys unchanged"
        fi
    fi
    if [ -e "$SHUTDOWN_LATCH" ]; then
        log_message "healthcheck: shutdown latch is active"
        handle_latched_shutdown
    fi
fi

echo "SSH and Nginx are running."
exit 0
