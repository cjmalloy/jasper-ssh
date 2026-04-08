FROM nginx:1.29.8-alpine3.23-slim
RUN apk add openssh openssh-server
COPY 40-setup-users.sh /docker-entrypoint.d
COPY healthcheck.sh /
