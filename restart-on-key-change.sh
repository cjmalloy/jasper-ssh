#!/bin/sh

[ "${CONFIG_CHANGE_MODE:-restart}" = restart ] || exit 0
[ -e /config/authorized_keys ] || exit 0

BASELINE_KEYS=$(mktemp)
CURRENT_KEYS=$(mktemp)
trap 'rm -f "$BASELINE_KEYS" "$CURRENT_KEYS"' EXIT
cp /tmp/authorized_keys.normalized "$BASELINE_KEYS"

while sleep 1; do
    sed 's/#.*//;s/^[	 ]*//;s/[	 ]*$//;/^$/d' /config/authorized_keys |
        LC_ALL=C sort -u > "$CURRENT_KEYS" || continue
    if ! cmp -s "$BASELINE_KEYS" "$CURRENT_KEYS"; then
        echo "The /config/authorized_keys file has been modified; exiting."
        kill -TERM 1
        exit 0
    fi
done
