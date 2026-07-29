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
| `STORAGE_ACCESS`     | List of comma separated user tags for which connecting via SFTP the storage volume is allowed. The storage volume must be mounted on `var/lib/jasper`                    |                          |
| `SSHD_LOG_LEVEL`     | Sets the LogLevel in sshd_config.                                                                                                                                                                              | INFO                     |
| `CONFIG_CHANGE_MODE` | Handles a semantic `/config/authorized_keys` change: `restart` exits the server immediately; `drain` terminates affected sessions while remaining healthy for a Deployment rollout.                              | `restart`                |

## Authorized-key changes

When the mounted `/config/authorized_keys` changes, the health check compares
the normalized key set, so reordering keys does not request a restart. If a user
loses any key, all of that user's existing sessions are terminated. Shutdown
remains latched even if the original file contents are restored. In the default
`restart` mode, the server exits immediately so a container restart policy can
replace it and load the new keys. In `drain` mode, the health check applies
per-user revocations but remains healthy; the rollout controller replaces the
pod so its `preStop` hook can drain the remaining sessions.

## Kubernetes termination draining

Configure `/shutdown.sh` as an executable Kubernetes `preStop` hook:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 20
  template:
    spec:
      terminationGracePeriodSeconds: 604800
      containers:
        - name: jasper-ssh
          lifecycle:
            preStop:
              exec:
                command: ["/shutdown.sh"]
```

The hook immediately stops the SSH listener so no new connections are accepted,
applies the same per-user revocations as the health check, then waits for the
remaining established SSH connections to close. It continues checking the
mounted keys while it drains so revocations projected after shutdown starts are
also applied. It has no internal timeout. The one-week
`terminationGracePeriodSeconds` is only an upper bound; disruptions or
administrative deletion can terminate sessions earlier.
`maxUnavailable: 0` preserves availability during an ordinary rollout, while
`maxSurge: 20` permits up to 20 extra pods but does not strictly limit how many
pods may be terminating. Deployments with more than 20 replicas require
controller-orchestrated batches for a strict termination concurrency limit.

## Kubernetes rollout controller

The optional controller image is published as
`ghcr.io/cjmalloy/jasper-ssh-controller`. It uses in-cluster authentication,
watches one authorized-keys ConfigMap, and patches the configured SSH
Deployment's pod-template annotation with the ConfigMap `resourceVersion`.
Repeated events for an already represented version do not produce another
patch. Deployments are patched in both `restart` and `drain` modes. In `drain`
mode, the resulting Deployment rollout invokes the old pods' `preStop` hooks
while their liveness checks remain healthy.

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
  keygen http-backend config-tester target-server target-server-restart \
  shutdown-hook
docker compose -f compose.test.yml up --build --no-deps \
  --abort-on-container-exit --exit-code-from test-runner test-runner
docker compose -f compose.test.yml down -v
```

The jasper-ssh suite verifies the headers sent to the upstream service, semantic
key comparison, per-user revocation, restart behavior, and termination draining.
Controller tests are separate and run with `go test ./...` from `controller/`.
