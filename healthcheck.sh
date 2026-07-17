#!/bin/sh

# Function to check if a service is running
service_check() {
    if ! pgrep $1 > /dev/null; then
        echo "$1 is not running."
        exit 1
    fi
}

terminate_revoked_user_connections() {
    current_keys=$(mktemp) || return
    if ! sed 's/#.*//;s/^[ \t]*//;s/[ \t]*$//;/^$/d' /config/authorized_keys > "$current_keys"; then
        rm -f "$current_keys"
        return
    fi

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=${user_keys#/home/}
        user=${user%%/*}

        # These files contain the normalized keys generated from the original input.
        while IFS= read -r key; do
            if ! grep -Fqx "$key" "$current_keys"; then
                # Any deleted key revokes every existing connection for that user.
                echo "An authorized key for $user was deleted; terminating their SSH connections."
                pkill -TERM -f "^sshd: ${user}(@| \\[)" 2>/dev/null || true
                sleep 1
                pkill -KILL -f "^sshd: ${user}(@| \\[)" 2>/dev/null || true
                break
            fi
        done < "$user_keys"
    done

    rm -f "$current_keys"
}

# Check if SSHD is running
service_check sshd

# Check if Nginx is running
service_check nginx

# Check if the authorized_keys has been modified and all SSH connections have closed
if [ -e /tmp/authorized_keys_checksum ] && [ -e /config/authorized_keys ]; then
    SHUTDOWN_LOCK=/tmp/authorized_keys_shutdown
    CURRENT_CHECKSUM=$(md5sum /config/authorized_keys | cut -d ' ' -f 1)
    ORIGINAL_CHECKSUM=$(cat /tmp/authorized_keys_checksum)
    if [ "$CURRENT_CHECKSUM" != "$ORIGINAL_CHECKSUM" ]; then
        touch "$SHUTDOWN_LOCK"
        terminate_revoked_user_connections
    fi
    SSH_PORT=$(awk 'tolower($1) == "port" { print $2; exit }' /etc/ssh/sshd_config)
    SSH_PORT=${SSH_PORT:-22}
    SSH_PORT_HEX=$(printf '%04X' "$SSH_PORT")
    TCP_STATE_ESTABLISHED="01"
    # In /proc/net/tcp, field 2 is the local address and field 4 is the TCP state.
    if ! SSHD_CONNECTION_COUNT=$(awk -v port="$SSH_PORT_HEX" -v state="$TCP_STATE_ESTABLISHED" 'BEGIN { count = 0 } $2 ~ "^[[:xdigit:]]+:" port "$" && $4 == state { count++ } END { print count }' /proc/net/tcp /proc/net/tcp6 2>/dev/null); then
        echo "Unable to count active SSH connections."
        SSHD_CONNECTION_COUNT=1
    fi
    if [ -e "$SHUTDOWN_LOCK" ] && [ "$SSHD_CONNECTION_COUNT" -eq 0 ]; then
        echo "The /config/authorized_keys file has been modified and there are no active SSH connections."
        exit 1
    fi
fi

# Both services are running
echo "SSH and Nginx are running."
exit 0
