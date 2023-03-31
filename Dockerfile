FROM nginx:alpine-slim
RUN apk add openssh openssh-server
COPY 40-create-nginx-config.sh /docker-entrypoint.d
COPY 50-create-sshd-config.sh /docker-entrypoint.d
