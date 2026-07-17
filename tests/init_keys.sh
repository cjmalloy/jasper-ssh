#!/usr/bin/env bash
set -euo pipefail

key_dir=/workspace/ssh_config
rm -f "$key_dir"/*

ssh-keygen -q -t ed25519 -N "" -C alice -f "$key_dir/alice"
ssh-keygen -q -t ed25519 -N "" -C bob -f "$key_dir/bob"
ssh-keygen -q -t ed25519 -N "" -C "charlie@custom-origin" -f "$key_dir/charlie"
ssh-keygen -q -t ed25519 -N "" -C alice -f "$key_dir/alice_second"
ssh-keygen -q -t rsa -b 3072 -N "" -f "$key_dir/host_key"

cat "$key_dir/alice.pub" "$key_dir/bob.pub" "$key_dir/charlie.pub" \
    "$key_dir/alice_second.pub" > "$key_dir/authorized_keys"
cp "$key_dir/authorized_keys" "$key_dir/authorized_keys.original"
chmod 600 "$key_dir/alice" "$key_dir/alice_second" "$key_dir/bob" \
    "$key_dir/charlie" "$key_dir/host_key"
touch "$key_dir/ready"

tail -f /dev/null
