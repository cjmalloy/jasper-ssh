#!/bin/sh
# shellcheck shell=ash

log_message() {
    printf '%s\n' "$*"
    [ ! -w /proc/1/fd/1 ] || printf '%s\n' "$*" > /proc/1/fd/1
}

# Compute a non-sensitive fingerprint from a normalized-keys file.
key_file_fingerprint() {
    local file="$1"
    local count hash output

    count=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo "?")
    if output=$(sha256sum "$file" 2>/dev/null); then
        hash=${output%% *}
    elif output=$(md5sum "$file" 2>/dev/null); then
        hash=${output%% *}
    else
        hash=unavailable
    fi
    printf '%s lines, hash=%.16s' "$count" "$hash"
}

normalize_keys() {
    sed 's/^[	 ]*//;s/[	 ]*$//;/^[	 ]*#/d;/^$/d' "$1" |
        LC_ALL=C sort -u > "$2"
}

# Fetch authorized_keys from the Kubernetes ConfigMap API and write normalized
# keys to $1.  The optional second argument overrides the service-account
# directory (default: /var/run/secrets/kubernetes.io/serviceaccount).
# Requires AUTHORIZED_KEYS_CONFIGMAP_NAME and NAMESPACE (or the SA namespace
# file) to be set. Returns 0 on success and 1 on any failure. Never logs key
# material.
fetch_api_keys() {
    local out="$1"
    local sa_dir="${2:-/var/run/secrets/kubernetes.io/serviceaccount}"
    local cm_name ns token http_status tmp_raw tmp_keys

    cm_name="${AUTHORIZED_KEYS_CONFIGMAP_NAME:-}"
    [ -n "$cm_name" ] || return 1

    ns="${NAMESPACE:-}"
    [ -n "$ns" ] || ns=$(cat "${sa_dir}/namespace" 2>/dev/null) || return 1

    if [ ! -r "${sa_dir}/token" ]; then
        log_message "key-revocation: SA token not readable at ${sa_dir}/token; skipping API fetch"
        return 1
    fi
    token=$(cat "${sa_dir}/token") || return 1

    tmp_raw=$(mktemp) || return 1
    tmp_keys=$(mktemp) || { rm -f "$tmp_raw"; return 1; }

    http_status=$(curl -s \
        --cacert "${sa_dir}/ca.crt" \
        -H "Authorization: Bearer ${token}" \
        -o "$tmp_raw" \
        -w '%{http_code}' \
        "https://kubernetes.default.svc/api/v1/namespaces/${ns}/configmaps/${cm_name}" \
        2>/dev/null || echo "failed")

    if [ "$http_status" != "200" ]; then
        log_message "key-revocation: API fetch failed (HTTP ${http_status}) for ${ns}/${cm_name}"
        rm -f "$tmp_raw" "$tmp_keys"
        return 1
    fi

    # Extract the authorized_keys value from the ConfigMap JSON without jq.
    # The value is a JSON string; newlines are encoded as \n sequences.
    # This handles both compact and pretty-printed API responses.
    awk '
        /"authorized_keys"[[:space:]]*:/ {
            sub(/.*"authorized_keys"[[:space:]]*:[[:space:]]*"/, "")
            sub(/"[,}[:space:]]*$/, "")
            gsub(/\\n/, "\n")
            printf "%s", $0
        }
    ' "$tmp_raw" > "$tmp_keys"
    rm -f "$tmp_raw"

    if [ ! -s "$tmp_keys" ]; then
        log_message "key-revocation: API response contained no authorized_keys field for ${ns}/${cm_name}"
        rm -f "$tmp_keys"
        return 1
    fi

    normalize_keys "$tmp_keys" "$out"
    local ret=$?
    rm -f "$tmp_keys"
    return $ret
}

user_from_keys_path() {
    local configured_user="${1#/home/}"
    printf '%s\n' "${configured_user%%/*}"
}

user_has_revoked_key() {
    local user_keys="$1"
    local current_keys="$2"
    local key

    while IFS= read -r key; do
        grep -Fqx -- "$key" "$current_keys" || return 0
    done < "$user_keys"
    return 1
}

signal_user_connections() {
    local signal="$1"
    local user="$2"
    local escaped_user
    local process_name
    local pid
    escaped_user=$(printf '%s' "$user" | sed 's/[][\\.^$*+?{}|()]/\\&/g')

    for process_name in sshd sshd-session; do
        pgrep -f "^${process_name}: ${escaped_user}([ @]|$)" 2>/dev/null |
            while IFS= read -r pid; do
                if kill "-$signal" "$pid" 2>/dev/null; then
                    log_message "Sent SIG${signal} to ${process_name} session for ${user} (PID ${pid})."
                else
                    log_message "Could not send SIG${signal} to ${process_name} session for ${user} (PID ${pid}); it may have already exited."
                fi
            done
    done
}

signal_users() {
    local signal="$1"
    local users="$2"
    local user

    for user in $users; do
        signal_user_connections "$signal" "$user"
    done
}

terminate_revoked_user_connections() {
    local current_keys="$1"
    local revoked_users=
    local user_keys
    local user

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=$(user_from_keys_path "$user_keys")
        user_has_revoked_key "$user_keys" "$current_keys" || continue

        log_message "An authorized key for $user was removed; terminating their SSH connections."
        revoked_users="$revoked_users $user"
    done

    signal_users TERM "$revoked_users"
    [ -z "$revoked_users" ] || sleep 1
    signal_users KILL "$revoked_users"
}
