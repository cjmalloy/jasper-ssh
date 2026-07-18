#!/bin/sh
set -eu

child_pid=
termination_requested=false
mode=${CONFIG_CHANGE_MODE:-restart}
restart_not_before=$(($(date +%s) + 10))

if [ "$mode" = restart ]; then
    rm -f /tmp/jasper-ssh-draining
fi

request_drain() {
    termination_requested=true
    /lifecycle.sh begin-drain "termination requested"
}

stop_child() {
    [ -z "$child_pid" ] || kill -TERM "$child_pid" 2>/dev/null || true
}

trap request_drain TERM INT QUIT
trap stop_child EXIT

/docker-entrypoint.sh "$@" &
child_pid=$!

while kill -0 "$child_pid" 2>/dev/null; do
    if [ -e /tmp/jasper-ssh-draining ]; then
        connection_count=$(/lifecycle.sh count 2>/dev/null || echo 1)
        if [ "$connection_count" -eq 0 ]; then
            if [ "$mode" = restart ] &&
                [ "$(date +%s)" -le "$restart_not_before" ]; then
                sleep 1
                continue
            fi
            echo "All SSH connections drained; stopping the container."
            stop_child
            wait "$child_pid" 2>/dev/null || true
            exit 0
        fi
    elif [ "$termination_requested" = true ]; then
        /lifecycle.sh begin-drain "termination requested"
    fi

    sleep 1 &
    wait $! 2>/dev/null || true
done

wait "$child_pid"
