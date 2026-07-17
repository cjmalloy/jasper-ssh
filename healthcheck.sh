#!/bin/sh

# Function to check if a service is running
service_check() {
    if ! pgrep $1 > /dev/null; then
        echo "$1 is not running."
        exit 1
    fi
}

# Check if SSHD is running
service_check sshd

# Check if Nginx is running
service_check nginx

# Check if the authorized_keys has been modified and all SSH connections have closed
if [ -e /tmp/authorized_keys_checksum ] && [ -e /config/authorized_keys ]; then
    CURRENT_CHECKSUM=$(md5sum /config/authorized_keys | cut -d ' ' -f 1)
    ORIGINAL_CHECKSUM=$(cat /tmp/authorized_keys_checksum)
    # 0016 is the hexadecimal representation of the default SSH port, 22.
    SSHD_CONNECTION_COUNT=$(awk '$2 ~ /:0016$/ && $4 == "01" { count++ } END { print count + 0 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    if [ "$CURRENT_CHECKSUM" != "$ORIGINAL_CHECKSUM" ] && [ "$SSHD_CONNECTION_COUNT" -eq 0 ]; then
        echo "The /config/authorized_keys file has been modified and there are no active SSH connections."
        exit 1
    fi
fi

# Both services are running
echo "SSH and Nginx are running."
exit 0
