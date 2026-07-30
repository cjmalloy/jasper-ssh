#!/bin/sh
set -eu

output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[ -n "$output" ]
keys=$(awk '{ printf "%s\\n", $0 }' /config/authorized_keys)
printf '{"kind":"ConfigMap","data":{"authorized_keys":"%s"}}' "$keys" > "$output"
printf '200'
