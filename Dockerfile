FROM nginx:1.30.0-alpine3.23-slim
RUN apk --no-cache upgrade && apk --no-cache add openssh openssh-server
COPY 40-setup-users.sh /docker-entrypoint.d
COPY healthcheck.sh /
