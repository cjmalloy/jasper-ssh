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

# Check if the authorized_keys has been modified
if [ -e /tmp/authorized_keys_checksum ] && [ -e /config/authorized_keys ]; then
    CURRENT_CHECKSUM=$(md5sum /config/authorized_keys | cut -d ' ' -f 1)
    ORIGINAL_CHECKSUM=$(cat /tmp/authorized_keys_checksum)
    if [ "$CURRENT_CHECKSUM" != "$ORIGINAL_CHECKSUM" ]; then
        echo "The /config/authorized_keys file has been modified."
        exit 1
    fi
fi

# Both services are running, and authorized_keys has not been modified
echo "SSH and Nginx are running, and /config/authorized_keys is unchanged."
exit 0
