#!/bin/sh
set -eu

probe=${1:-health}
mode=${CONFIG_CHANGE_MODE:-restart}

case "$probe" in
    health|live|ready) ;;
    *)
        echo "Usage: $0 [health|live|ready]" >&2
        exit 2
        ;;
esac

# Function to check if a service is running
service_check() {
    if ! pgrep "$1" > /dev/null; then
        echo "$1 is not running."
        exit 1
    fi
}

service_check nginx

if [ -e /tmp/jasper-ssh-draining ]; then
    case "$probe" in
        live)
            echo "SSH connections are draining."
            exit 0
            ;;
        ready)
            echo "SSH is not accepting new connections."
            exit 1
            ;;
        health)
            if [ "$mode" = drain ]; then
                echo "SSH connections are draining."
                exit 0
            fi
            echo "SSH connections are draining before restart."
            exit 0
            ;;
    esac
fi

service_check sshd
echo "SSH and Nginx are running."
