#!/bin/sh

echo "Writing SSHD Config and NGINX Configs for Users"
echo "CONFIG_CHANGE_MODE: ${CONFIG_CHANGE_MODE:-restart}"

base_port=38022
sshd_config="/etc/ssh/sshd_config"

# Base SSHD Config
sshdConfig="
LogLevel ${SSHD_LOG_LEVEL:-INFO}
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin no
PasswordAuthentication no
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
UseDNS no
PermitOpen none
Subsystem sftp internal-sftp
ForceCommand /bin/false
"
echo "$sshdConfig" > "$sshd_config"

# Convert the list into a space-separated list
STORAGE_ACCESS=$(echo $STORAGE_ACCESS | tr ',' ' ')

# Chroot a user into a read-only bind mount of their origin's Jasper storage
# folder. Jasper stores files in /var/lib/jasper/<origin>, keeping the '@'.
setup_storage_access() {
    local user="$1"
    local origin="$2"
    local source="/var/lib/jasper/$origin"
    local user_chroot="/opt/chrooted-sftp/$user"

    case "$origin" in
        */*|.|..)
            echo "Warning: invalid origin '$origin' for $user; skipping storage access." >&2
            return
            ;;
    esac
    if [ ! -d "$source" ]; then
        echo "Warning: $source does not exist; skipping storage access for $user." >&2
        return
    fi

    # sshd requires every component of the chroot path to be root owned and
    # not group or world writable
    mkdir -p "$user_chroot/storage" "$user_chroot/etc"
    chown root:root /opt/chrooted-sftp "$user_chroot" "$user_chroot/etc"
    chmod 755 /opt/chrooted-sftp "$user_chroot" "$user_chroot/etc"
    # sshd resolves port forwarding targets inside the chroot
    printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > "$user_chroot/etc/hosts"
    chmod 644 "$user_chroot/etc/hosts"

    if ! mountpoint -q "$user_chroot/storage"; then
        if ! mount --bind "$source" "$user_chroot/storage"; then
            echo "Warning: could not bind mount $source for $user; skipping storage access." >&2
            rm -f "$user_chroot/etc/hosts"
            rmdir "$user_chroot/storage" "$user_chroot/etc" "$user_chroot" 2>/dev/null
            return
        fi
        mount -o remount,bind,ro "$user_chroot/storage" ||
            echo "Warning: could not remount $user_chroot/storage read-only; relying on internal-sftp -R." >&2
    fi

    echo "    ChrootDirectory $user_chroot" >> "$sshd_config"
    echo "    ForceCommand internal-sftp -R -d /storage" >> "$sshd_config"
    echo "Read-only storage access to $source enabled for $user."
}

# Function to create user folder, set up authorized_keys, add sshd_config match user and create nginx server config
setup_user() {
    key="$1"

    # Extract user tag and optional host origin from the key comment
    comment_field=$(echo "$key" | awk '{print $NF}')
    user_tag=$(echo "$comment_field" | cut -d '@' -f 1)
    origin_part=$(echo "$comment_field" | cut -s -d '@' -f 2)

    # Concatenate '@' with origin if origin is not empty
    user_origin=""
    if [ -n "$origin_part" ]; then
        user_origin="@$origin_part"
    else
        user_origin="$LOCAL_ORIGIN"
    fi

    # Fallback logic for user tag and local origin
    if [ -z "$user_tag" ] || [ "$user_tag" = "@"* ]; then
        if [ -n "$USER_TAG" ]; then
            user_tag="$USER_TAG"
        else
            echo "Error: USER_TAG is not set for user $user" >&2
            exit 1
        fi
    fi

    # Transform to create a unique Linux username
    # Remove + or _ prefix
    user=$(echo "$user_tag" | sed 's/[+_]//g')
    if [ -n "$origin_part" ]; then
        # Concatenate origin and user tag
        user="${origin_part}_${user}"
    fi
    # Normalize by replacing '.' with '-' and '/' with '_' in user tag
    user=$(echo "$user" | sed 's/\./-/g' | sed 's/\//_/g')

    # User home dir
    home_dir="/home/$user"

    # Check if the user already exists
    if grep -q "^$user:" /etc/passwd; then
        echo "Adding extra SSH pubkey for $user."
        echo "$key" >> "$home_dir/.ssh/authorized_keys"
        return
    fi

    # Create user
    adduser --disabled-password --gecos "" "$user"
    passwd -u "$user"
    port=$((base_port++))

    # Create user home directory if it doesn't exist
    mkdir -p "$home_dir/.ssh"
    chmod 700 "$home_dir/.ssh"

    # Write the key to the user's authorized_keys
    echo "$key" > "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"

    # Set banner to report the port chosen
    echo "$port" > "$home_dir/banner.txt"

    chown -R $user:$user "$home_dir"

    # Append to SSHD Config for user-specific PermitOpen
    echo "Match User $user" >> "$sshd_config"
    echo "    PermitOpen localhost:$port" >> "$sshd_config"
    echo "    Banner $home_dir/banner.txt" >> "$sshd_config"

    # Give read-only SFTP access to the Jasper storage folder for this origin
    storage_access=""
    for tag in $STORAGE_ACCESS; do
        if [ "$tag" = "$user_tag$user_origin" ]; then
            storage_access=true
        fi
    done
    if [ -n "$storage_access" ]; then
        setup_storage_access "$user" "${user_origin:-default}"
    fi

    # Write NGINX config for the user
    nginx_config="
server {
    listen       $port;
    server_name  localhost;
    client_body_buffer_size 10m;

    location / {
        proxy_pass ${UPSTREAM-http://localhost:8081/};

        proxy_set_header Local-Origin \"${user_origin}\";
        proxy_set_header User-Tag \"${user_tag}\";
        proxy_set_header User-Role \"${USER_ROLE}\";
        proxy_set_header Read-Access \"${READ_ACCESS}\";
        proxy_set_header Write-Access \"${WRITE_ACCESS}\";
        proxy_set_header Tag-Read-Access \"${TAG_READ_ACCESS}\";
        proxy_set_header Tag-Write-Access \"${TAG_WRITE_ACCESS}\";
        proxy_set_header Authorization \"Bearer ${TOKEN}\";

        # Add WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        # Increase timeouts for WebSocket connections
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
"
    echo "$nginx_config" > "/etc/nginx/conf.d/${user}.conf"

    echo "Set up for $user completed."
}

# Main logic for processing keys
process_keys() {
    keys="$1"
    echo "$keys" | while IFS= read -r line; do
        # Remove comments
        line=$(echo "$line" | sed 's/\#.*//')

        # Trim leading and trailing spaces
        line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')

        # Skip empty lines
        [ -z "$line" ] && continue

        # Call setup_user function
        setup_user "$line"
    done
}

# Check for AUTHORIZED_KEYS environment variable or mounted file
if [ -n "$AUTHORIZED_KEYS" ]; then
    echo "ENV Authorized Keys set"
    process_keys "$AUTHORIZED_KEYS"
elif [ -e /config/authorized_keys ]; then
    echo "Authorized Keys file mounted"
    rm -f /tmp/authorized_keys_shutdown
    rm -rf /tmp/authorized_keys_revocation_started
    sed 's/^[	 ]*//;s/[	 ]*$//;/^[	 ]*#/d;/^$/d' /config/authorized_keys |
        LC_ALL=C sort -u > /tmp/authorized_keys.normalized
    process_keys "$(cat /config/authorized_keys)"
else
    echo "No Authorized Keys" >&2
    exit 1
fi

# Check for HOST_KEY environment variable or mounted file
if [ -n "$HOST_KEY" ]; then
    echo "ENV Host Key set"
    echo "$HOST_KEY" > /etc/ssh/ssh_host_rsa_key
    chmod 600 /etc/ssh/ssh_host_rsa_key
elif [ -e /secrets/host_key ]; then
    echo "Host Key file mounted"
    cp /secrets/host_key /etc/ssh/ssh_host_rsa_key
    chmod 600 /etc/ssh/ssh_host_rsa_key
else
    echo "No Host Key" >&2
    exit 1
fi

/usr/sbin/sshd -e -D &
SSHD_PID=$!
echo "sshd started with PID $SSHD_PID"
# Trap both SIGQUIT and SIGTERM and forward as SIGQUIT to sshd
trap 'echo "Received SIGQUIT, forwarding to sshd (PID $SSHD_PID)"; kill -s SIGQUIT $SSHD_PID' SIGQUIT
trap 'echo "Received SIGTERM, forwarding to sshd (PID $SSHD_PID)"; kill -s SIGQUIT $SSHD_PID' SIGTERM
