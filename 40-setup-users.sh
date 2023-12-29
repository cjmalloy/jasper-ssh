#!/bin/sh

echo "Writing SSHD Config and NGINX Configs for Users"

base_port=38022
sshd_config="/etc/ssh/sshd_config"

# Base SSHD Config
sshdConfig="
LogLevel ${SSHD_LOG_LEVEL:-INFO}
PermitRootLogin no
PasswordAuthentication no
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
ForceCommand /bin/false
PermitOpen none
"
echo "$sshdConfig" > "$sshd_config"

# Function to create user folder, set up authorized_keys, add sshd_config match user and create nginx server config
setup_user() {
    key="$1"
    port=$((base_port++))

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
    # Normalize by replacing '/' with '_' in user tag
    user=$(echo "$user" | sed 's/\//_/g')

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

    # Write NGINX config for the user
    nginx_config="
server {
    listen       $port;
    listen  [::]:$port;
    server_name  localhost;

    proxy_set_header Local-Origin \"${user_origin}\";
    proxy_set_header User-Tag \"${user_tag}\";
    proxy_set_header User-Role \"${USER_ROLE}\";
    proxy_set_header Read-Access \"${READ_ACCESS}\";
    proxy_set_header Write-Access \"${WRITE_ACCESS}\";
    proxy_set_header Tag-Read-Access \"${TAG_READ_ACCESS}\";
    proxy_set_header Tag-Write-Access \"${TAG_WRITE_ACCESS}\";

    location / {
        proxy_pass ${UPSTREAM-http://localhost:8081/};
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
    AUTHORIZED_KEYS_CHECKSUM=$(md5sum /config/authorized_keys | cut -d ' ' -f 1)
    echo $AUTHORIZED_KEYS_CHECKSUM > /tmp/authorized_keys_checksum
    process_keys "$(cat /config/authorized_keys)"
else
    echo "No Authorized Keys" >&2
    exit 1
fi

# Generate SSH host keys and start the SSH daemon
ssh-keygen -A
/usr/sbin/sshd -e -D &
SSHD_PID=$!
echo "sshd started with PID $SSHD_PID"
# Trap both SIGQUIT and SIGTERM and forward as SIGQUIT to sshd
trap 'echo "Received SIGQUIT, forwarding to sshd (PID $SSHD_PID)"; kill -s SIGQUIT $SSHD_PID' SIGQUIT
trap 'echo "Received SIGTERM, forwarding to sshd (PID $SSHD_PID)"; kill -s SIGQUIT $SSHD_PID' SIGTERM
