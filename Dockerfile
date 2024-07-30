FROM nginx:1.27.0-alpine3.19-slim
RUN apk add openssh openssh-server
COPY 40-setup-users.sh /docker-entrypoint.d
COPY healthcheck.sh /
