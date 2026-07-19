#!/bin/sh

[ "${CONFIG_CHANGE_MODE:-restart}" = restart ] || exit 0
[ -e /config/authorized_keys ] || exit 0

baseline_keys=$(mktemp)
current_keys=$(mktemp)
trap 'rm -f "$baseline_keys" "$current_keys"' EXIT
cp /tmp/authorized_keys.normalized "$baseline_keys"

while sleep 1; do
    sed 's/#.*//;s/^[	 ]*//;s/[	 ]*$//;/^$/d' /config/authorized_keys |
        LC_ALL=C sort -u > "$current_keys" || continue
    if ! cmp -s "$baseline_keys" "$current_keys"; then
        echo "The /config/authorized_keys file has been modified; exiting."
        kill -TERM 1
        exit 0
    fi
done
