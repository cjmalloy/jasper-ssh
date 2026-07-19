#!/bin/sh

CONFIG_CHANGE_MODE=${CONFIG_CHANGE_MODE:-restart}
NORMALIZED_KEYS=/tmp/authorized_keys.normalized
SHUTDOWN_LATCH=/tmp/authorized_keys_shutdown
REVOCATION_LOCK=/tmp/authorized_keys_revocation_started

normalize_keys() {
    sed 's/#.*//;s/^[	 ]*//;s/[	 ]*$//;/^$/d' "$1" |
        LC_ALL=C sort -u > "$2"
}

signal_user_connections() {
    signal=$1
    user=$2
    escaped_user=$(printf '%s' "$user" | sed 's/[][\\.^$*+?{}|()]/\\&/g')

    for process_name in sshd sshd-session; do
        pgrep -f "^${process_name}: ${escaped_user}([ @]|$)" 2>/dev/null |
            while IFS= read -r pid; do
                kill "-$signal" "$pid" 2>/dev/null || true
            done
    done
}

terminate_revoked_user_connections() {
    current_keys=$1
    revoked_users=

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=${user_keys#/home/}
        user=${user%%/*}

        while IFS= read -r key; do
            if ! grep -Fqx -- "$key" "$current_keys"; then
                echo "An authorized key for $user was removed; terminating their SSH connections."
                revoked_users="$revoked_users $user"
                break
            fi
        done < "$user_keys"
    done

    for user in $revoked_users; do
        signal_user_connections TERM "$user"
    done
    [ -z "$revoked_users" ] || sleep 1
    for user in $revoked_users; do
        signal_user_connections KILL "$user"
    done
}

remove_configured_users() {
    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=${user_keys#/home/}
        user=${user%%/*}

        echo "Removing configuration for $user before restart."
        rm -f "/etc/nginx/conf.d/$user.conf"
        if awk -F: -v user="$user" '$1 == user { found = 1 } END { exit !found }' \
            /etc/passwd && ! deluser "$user"; then
            echo "Could not remove user $user; restart aborted." >&2
            return 1
        fi
        rm -rf "/home/$user"
    done
}

# Function to check if a service is running
service_check() {
    if ! pgrep "$1" > /dev/null; then
        echo "$1 is not running."
        exit 1
    fi
}

# Check if SSHD is running
service_check sshd

# Check if Nginx is running
service_check nginx

# Check if the authorized keys have semantically changed
if [ -e "$NORMALIZED_KEYS" ] && [ -e /config/authorized_keys ]; then
    CURRENT_KEYS=$(mktemp)
    trap 'rm -f "$CURRENT_KEYS"' EXIT
    if normalize_keys /config/authorized_keys "$CURRENT_KEYS" &&
        ! cmp -s "$NORMALIZED_KEYS" "$CURRENT_KEYS"; then
        touch "$SHUTDOWN_LATCH"
        if mkdir "$REVOCATION_LOCK" 2>/dev/null; then
            if ! cmp -s "$NORMALIZED_KEYS" "$CURRENT_KEYS"; then
                terminate_revoked_user_connections "$CURRENT_KEYS"
                cp "$CURRENT_KEYS" "$NORMALIZED_KEYS"
            fi
            rmdir "$REVOCATION_LOCK"
        fi
    fi
    if [ -e "$SHUTDOWN_LATCH" ]; then
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
        CONNECTION_COUNT=$(awk '
            $2 ~ /:0016$/ && $4 == "01" { count++ }
            END { print count + 0 }
        ' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
        if [ "$CONNECTION_COUNT" -eq 0 ]; then
            echo "The /config/authorized_keys file has been modified."
            kill -TERM 1
            exit 1
        fi
        echo "The /config/authorized_keys file has been modified; draining $CONNECTION_COUNT SSH connection(s)."
        exit 0
    fi
fi

# Both services are running, and authorized_keys has not been modified
echo "SSH and Nginx are running, and /config/authorized_keys is unchanged."
exit 0
