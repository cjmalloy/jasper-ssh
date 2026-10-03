#!/bin/sh
set -eu

fail() {
    echo "$1" > /test-state/config-error
    touch /test-state/config-tested
    tail -f /dev/null
}

if output=$(
    env -u AUTHORIZED_KEYS -u HOST_KEY \
        /docker-entrypoint.d/40-setup-users.sh 2>&1
); then
    fail "Startup succeeded without authorized keys"
fi
echo "$output" | grep -Fq "No Authorized Keys" ||
    fail "Startup did not explain that authorized keys were missing"

if output=$(
    env AUTHORIZED_KEYS="$(cat /keys/alice.pub)" \
        USER_ROLE=test-role READ_ACCESS=test-read WRITE_ACCESS=test-write \
        TAG_READ_ACCESS=test-tag-read TAG_WRITE_ACCESS=test-tag-write \
        LOCAL_ORIGIN=@test-origin TOKEN=test-token \
        /docker-entrypoint.d/40-setup-users.sh 2>&1
); then
    fail "Startup succeeded without a host key"
fi
echo "$output" | grep -Fq "No Host Key" ||
    fail "Startup did not explain that the host key was missing"

touch /test-state/config-tested
tail -f /dev/null
