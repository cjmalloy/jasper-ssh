#!/bin/sh
# shellcheck shell=ash

log_message() {
    printf '%s\n' "$*"
    [ ! -w /proc/1/fd/1 ] || printf '%s\n' "$*" > /proc/1/fd/1
}

# Compute a non-sensitive fingerprint from a normalized-keys file.
# Output: "<N> lines, hash=<16-char-prefix>"
key_file_fingerprint() {
    local file="$1"
    local count hash
    count=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo "?")
    hash=$(sha256sum "$file" 2>/dev/null | cut -c1-16 \
           || md5sum "$file" 2>/dev/null | cut -c1-16 \
           || echo "unavailable")
    printf '%s lines, hash=%s' "$count" "$hash"
}

# Log file metadata (mtime, symlink target) for a given path.
# Degrades gracefully when stat or readlink are unavailable.
log_path_metadata() {
    local prefix="$1"
    local path="$2"
    local mtime target
    if [ ! -e "$path" ]; then
        log_message "${prefix} ${path}: not found"
        return
    fi
    mtime=$(stat -c '%y' "$path" 2>/dev/null \
            || stat -f '%Sm' "$path" 2>/dev/null \
            || echo "unavailable")
    target=$(readlink "$path" 2>/dev/null || echo "")
    if [ -n "$target" ]; then
        log_message "${prefix} ${path}: exists, mtime=${mtime}, symlink->${target}"
    else
        log_message "${prefix} ${path}: exists, mtime=${mtime}"
    fi
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
    log_message "key-revocation: fetched keys from API (${ns}/${cm_name})"
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
    local pids
    local pid
    local proc_desc
    local remaining
    local count
    escaped_user=$(printf '%s' "$user" | sed 's/[][\\.^$*+?{}|()]/\\&/g')

    for process_name in sshd sshd-session; do
        log_message "key-revocation: checking for ${process_name} sessions of ${user}"
        pids=$(pgrep -f "^${process_name}: ${escaped_user}([ @]|$)" 2>/dev/null || true)
        if [ -z "$pids" ]; then
            log_message "key-revocation: no ${process_name} session found for ${user}"
            continue
        fi
        printf '%s\n' "$pids" | while IFS= read -r pid; do
            if _desc=$(2>/dev/null tr '\0' ' ' < "/proc/${pid}/cmdline"); then
                proc_desc=$(printf '%.80s' "$_desc")
            else
                proc_desc="unavailable"
            fi
            log_message "key-revocation: matched ${process_name} PID ${pid}: ${proc_desc}"
            if kill "-$signal" "$pid" 2>/dev/null; then
                log_message "Sent SIG${signal} to ${process_name} session for ${user} (PID ${pid})."
            else
                log_message "Could not send SIG${signal} to ${process_name} session for ${user} (PID ${pid}); it may have already exited."
            fi
        done
    done

    # Log whether any session processes remain after signaling.
    remaining=0
    for process_name in sshd sshd-session; do
        count=$(pgrep -f "^${process_name}: ${escaped_user}([ @]|$)" 2>/dev/null | wc -l || echo 0)
        remaining=$((remaining + count))
    done
    if [ "$remaining" -gt 0 ]; then
        log_message "key-revocation: ${remaining} session(s) remain for ${user} after SIG${signal}"
    else
        log_message "key-revocation: no sessions remain for ${user} after SIG${signal}"
    fi
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
    local key_count
    local fp

    fp=$(key_file_fingerprint "$current_keys")
    log_message "key-revocation: checking for revocations, current keys: ${fp}"

    for user_keys in /home/*/.ssh/authorized_keys; do
        [ -f "$user_keys" ] || continue
        user=$(user_from_keys_path "$user_keys")
        key_count=$(wc -l < "$user_keys" 2>/dev/null | tr -d ' ' || echo "?")
        log_message "key-revocation: evaluating ${user} (${key_count} configured key(s))"
        if user_has_revoked_key "$user_keys" "$current_keys"; then
            log_message "An authorized key for $user was removed; terminating their SSH connections."
            revoked_users="$revoked_users $user"
        else
            log_message "key-revocation: no revoked keys for ${user}"
        fi
    done

    if [ -z "$revoked_users" ]; then
        log_message "key-revocation: no revoked users"
    else
        log_message "key-revocation: revoked user(s):${revoked_users}"
    fi

    signal_users TERM "$revoked_users"
    [ -z "$revoked_users" ] || sleep 1
    signal_users KILL "$revoked_users"
}
