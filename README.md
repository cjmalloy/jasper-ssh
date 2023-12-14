# jasper-ssh
Create an SSH authenticated jasper proxy

| Environment Variable | Description                                                                                                                                                              | Default Value            |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------|
| `AUTHORIZED_KEYS`    | List of public SSH keys to admit access. The comment field may contain a user tag and optionally the user origin to support multiple users.                              |                          |
| `UPSTREAM`           | URL for upstream Jasper API.                                                                                                                                             | `http://localhost:8081/` |
| `USER_TAG`           | Sets `User-Tag` header. Overridden by the user tag in the authorized_keys comment field. Requires upstream server to have `JASPER_ALLOW_USER_TAG_HEADER` set.            |                          |
| `USER_ROLE`          | Sets `User-Role` header. Requires upstream server to have `JASPER_ALLOW_USER_ROLE_HEADER` set.                                                                           |                          |
| `LOCAL_ORIGIN`       | Sets `Local-Origin` header. Overridden by the user origin in the authorized_keys comment field. Requires upstream server to have `JASPER_ALLOW_LOCAL_ORIGIN_HEADER` set. |                          |
| `READ_ACCESS`        | Sets `Read-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                             |                          |
| `WRITE_ACCESS`       | Sets `Write-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                            |                          |
| `TAG_READ_ACCESS`    | Sets `Tag-Read-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                         |                          |
| `TAG_WRITE_ACCESS`   | Sets `Tag-Write-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                        |                          |
| `SSHD_LOG_LEVEL`     | Sets the LogLevel in sshd_config.                                                                                                                                        | INFO                     |
