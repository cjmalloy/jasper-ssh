#!/bin/sh
# Check if SSHD is running
if ! pgrep sshd > /dev/null; then
    echo "SSHD is not running."
    exit 1
fi

# Check if Nginx is running
if ! pgrep nginx > /dev/null; then
    echo "Nginx is not running."
    exit 1
fi

# Both services are running
echo "Both SSHD and Nginx are running."
exit 0
