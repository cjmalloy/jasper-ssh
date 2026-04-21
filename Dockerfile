FROM nginx:1.30.0-alpine3.23-slim
# Intentionally pinned one release behind to verify Renovate updates this package.
# renovate: datasource=repology depName=alpine_3_23/openssh versioning=loose
ARG OPENSSH_VERSION=10.1_p1-r0
RUN apk add --no-cache \
    openssh=${OPENSSH_VERSION} \
    openssh-server=${OPENSSH_VERSION}
COPY 40-setup-users.sh /docker-entrypoint.d
COPY healthcheck.sh /
