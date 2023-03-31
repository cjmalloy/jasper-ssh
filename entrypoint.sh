#!/bin/bash

if [ -n "$AUTHORIZED_KEYS" ]; then
  echo "ENV Authorized Keys set"
  echo "$AUTHORIZED_KEYS" > /etc/ssh/authorized_keys
elif [ -f /authorized_keys ]; then
  echo "Authorized Keys file mounted"
  cp /authorized_keys /etc/ssh/authorized_keys
else
  echo "No Authorized Keys"
  exit 1
fi

echo "Writing Nginx Config"

nginxConfig="
server {
    listen       8022;
    listen  [::]:8022;
    server_name  localhost;

    more_set_input_headers "Local-Origin: ${ORIGIN}";
    more_set_input_headers "Authorization: ${AUTHORIZATION}";

    location / {
        proxy_pass ${UPSTREAM}
    }
}
"
echo "$nginxConfig"
echo "$nginxConfig" > /etc/nginx/conf.d/default.conf
echo "Wrote to /etc/nginx/conf.d/default.conf"

sshdConfig="
PermitRootLogin prohibit-password
PasswordAuthentication no
AuthorizedKeysFile /etc/ssh/authorized_keys
PermitOpen localhost:8022
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
ForceCommand /bin/false
"
echo "$sshdConfig"
echo "$sshdConfig" > /etc/ssh/sshd_config

chmod 600 /etc/ssh/authorized_keys
ssh-keygen -A
/usr/sbin/sshd -D -e

