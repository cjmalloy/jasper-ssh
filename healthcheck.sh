#!/bin/sh

CONFIG_CHANGE_MODE=${CONFIG_CHANGE_MODE:-restart}

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

# Check if the authorized_keys has been modified
if [ -e /tmp/authorized_keys_checksum ] && [ -e /config/authorized_keys ]; then
    SHUTDOWN_LATCH=/tmp/authorized_keys_shutdown
    CURRENT_CHECKSUM=$(md5sum /config/authorized_keys | cut -d ' ' -f 1)
    ORIGINAL_CHECKSUM=$(cat /tmp/authorized_keys_checksum)
    if [ "$CURRENT_CHECKSUM" != "$ORIGINAL_CHECKSUM" ]; then
        touch "$SHUTDOWN_LATCH"
    fi
    if [ -e "$SHUTDOWN_LATCH" ]; then
        case "$CONFIG_CHANGE_MODE" in
            restart)
                echo "The /config/authorized_keys file has been modified."
                exit 1
                ;;
            drain) ;;
            *)
                echo "CONFIG_CHANGE_MODE must be restart or drain."
                exit 1
                ;;
        esac
        CONNECTION_COUNT=$(awk '
            $2 ~ /:0016$/ && $4 == "01" { count++ }
            END { print count + 0 }
        ' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
        if [ "$CONNECTION_COUNT" -eq 0 ]; then
            echo "The /config/authorized_keys file has been modified."
            exit 1
        fi
        echo "The /config/authorized_keys file has been modified; draining $CONNECTION_COUNT SSH connection(s)."
        exit 0
    fi
fi

# Both services are running, and authorized_keys has not been modified
echo "SSH and Nginx are running, and /config/authorized_keys is unchanged."
exit 0
