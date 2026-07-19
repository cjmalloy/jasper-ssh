# jasper-ssh
Create an SSH authenticated [jasper](https://github.com/cjmalloy/jasper) proxy

| Environment Variable | Description                                                                                                                                                                                                    | Default Value            |
|----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------|
| `HOST_KEY`           | SSH Server host key. If not set will also check for the file `/secrets/host_key`.                                                                                                                              |                          |
| `AUTHORIZED_KEYS`    | List of public SSH keys to admit access. The comment field may contain a user tag and optionally the user origin to support multiple users. If not set will also check for the file `/config/authorized_keys`. |                          |
| `UPSTREAM`           | URL for upstream Jasper API.                                                                                                                                                                                   | `http://localhost:8081/` |
| `TOKEN`              | JWT bearer token set to Authorization header.                                                                                                                                                                  |  |
| `USER_TAG`           | Sets `User-Tag` header. Overridden by the user tag in the authorized_keys comment field. Requires upstream server to have `JASPER_ALLOW_USER_TAG_HEADER` set.                                                  |                          |
| `USER_ROLE`          | Sets `User-Role` header. Requires upstream server to have `JASPER_ALLOW_USER_ROLE_HEADER` set.                                                                                                                 |                          |
| `LOCAL_ORIGIN`       | Sets `Local-Origin` header. Overridden by the user origin in the authorized_keys comment field. Requires upstream server to have `JASPER_ALLOW_LOCAL_ORIGIN_HEADER` set.                                       |                          |
| `READ_ACCESS`        | Sets `Read-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                                                                   |                          |
| `WRITE_ACCESS`       | Sets `Write-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                                                                  |                          |
| `TAG_READ_ACCESS`    | Sets `Tag-Read-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                                                               |                          |
| `TAG_WRITE_ACCESS`   | Sets `Tag-Write-Access` header. Requires upstream server to have `JASPER_ALLOW_AUTH_HEADERS` set.                                                                                                              |                          |
| `SSHD_LOG_LEVEL`     | Sets the LogLevel in sshd_config.                                                                                                                                                                              | INFO                     |
| `CONFIG_CHANGE_MODE` | Controls health after `/config/authorized_keys` changes: `restart` fails immediately; `drain` waits for established SSH connections to close.                                                                | `restart`                |

## Authorized-key changes

When the mounted `/config/authorized_keys` checksum changes, shutdown remains
latched even if the original file contents are restored. In the default
`restart` mode, the health check fails immediately so the orchestrator can
replace the container and load the new keys. In `drain` mode, it continues to
pass while established SSH connections remain and fails once they close.

## Kubernetes rollout controller

The optional controller image is published as
`ghcr.io/cjmalloy/jasper-ssh-controller`. It uses in-cluster authentication,
watches one authorized-keys ConfigMap, and patches the configured SSH
Deployment's pod-template annotation with the ConfigMap `resourceVersion`.
Repeated events for an already represented version do not produce another
patch.

| Environment variable | Description | Default |
|----------------------|-------------|---------|
| `NAMESPACE` | Namespace containing the ConfigMap and Deployment. | `default` |
| `AUTHORIZED_KEYS_CONFIGMAP_NAME` | Authorized-keys ConfigMap to watch. Required. | |
| `SSH_DEPLOYMENT_NAME` | jasper-ssh Deployment to patch. Required. | |
| `ROLLOUT_ANNOTATION_KEY` | Pod-template annotation used to request rollouts. | `jasper-ssh.cjmalloy.com/authorized-keys-resource-version` |
| `ROLLOUT_DELAY` | Optional non-negative Go duration before reconciliation, allowing projected keys to reach existing pods first. | `0s` |
| `HEALTH_ADDRESS` | Controller health server listen address. | `:8080` |

The controller exposes `/livez` and `/readyz` on its health address and handles
`SIGINT` and `SIGTERM` gracefully. Mount the watched ConfigMap at
`/config/authorized_keys`. An example namespaced ServiceAccount, Role, and
RoleBinding is available at `controller/rbac.yaml`; update its resource
names to match your ConfigMap and Deployment.

## Tests

Run the jasper-ssh Bash integration suite with Docker Compose:

```sh
docker compose -f compose.test.yml up --build --wait \
  keygen http-backend config-tester target-server target-server-restart
docker compose -f compose.test.yml up --build --no-deps \
  --abort-on-container-exit --exit-code-from test-runner test-runner
docker compose -f compose.test.yml down -v
```

The jasper-ssh suite verifies the headers sent to the upstream service and both
restart and drain health-check behavior after an authorized-key change.
Controller tests are separate and run with `go test ./...` from `controller/`.
