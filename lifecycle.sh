#!/bin/sh
set -eu

drain_file=/tmp/jasper-ssh-draining
normalized_keys=/tmp/authorized_keys.normalized
sshd_pid_file=/tmp/sshd.pid

normalize_keys() {
    sed 's/#.*//;s/^[	 ]*//;s/[	 ]*$//;/^$/d' "$1" |
        LC_ALL=C sort -u > "$2"
}

connection_count() {
    ssh_port=$(awk 'tolower($1) == "port" { print $2; exit }' /etc/ssh/sshd_config)
    ssh_port=${ssh_port:-22}
    ssh_port_hex=$(printf '%04X' "$ssh_port")

    awk -v port="$ssh_port_hex" '
        BEGIN { count = 0 }
        $2 ~ "^[[:xdigit:]]+:" port "$" && $4 == "01" { count++ }
        END { print count }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

signal_user_connections() {
    signal=$1
    user=$2

    for process_name in sshd sshd-session; do
        pgrep -f "^${process_name}: ${user}" 2>/dev/null |
            while IFS= read -r pid; do
                kill "-$signal" "$pid" 2>/dev/null || true
            done
    done
}

terminate_revoked_user_connections() {
    current_keys=$1

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=${user_keys#/home/}
        user=${user%%/*}

        while IFS= read -r key; do
            if ! grep -Fqx -- "$key" "$current_keys"; then
                echo "An authorized key for $user was removed; terminating their SSH connections."
                signal_user_connections TERM "$user"
                sleep 1
                signal_user_connections KILL "$user"
                break
            fi
        done < "$user_keys"
    done
}

stop_accepting_connections() {
    [ -s "$sshd_pid_file" ] || return 0
    sshd_pid=$(cat "$sshd_pid_file")
    kill -TERM "$sshd_pid" 2>/dev/null || true
}

begin_drain() {
    reason=$1

    if [ ! -e "$drain_file" ]; then
        touch "$drain_file"
        echo "Draining SSH connections: $reason."
    fi
    stop_accepting_connections
}

watch_keys() {
    while :; do
        sleep 1
        current_keys=$(mktemp)
        if ! normalize_keys /config/authorized_keys "$current_keys"; then
            rm -f "$current_keys"
            continue
        fi

        if ! cmp -s "$normalized_keys" "$current_keys"; then
            begin_drain "authorized keys changed"
            terminate_revoked_user_connections "$current_keys"
            mv "$current_keys" "$normalized_keys"
            exit 0
        fi
        rm -f "$current_keys"
    done
}

case "${1:-}" in
    begin-drain)
        begin_drain "${2:-shutdown requested}"
        ;;
    count)
        connection_count
        ;;
    initialize)
        normalize_keys /config/authorized_keys "$normalized_keys"
        ;;
    stop-listener)
        stop_accepting_connections
        ;;
    watch)
        watch_keys
        ;;
    *)
        echo "Usage: $0 {begin-drain|count|initialize|stop-listener|watch}" >&2
        exit 2
        ;;
esac
