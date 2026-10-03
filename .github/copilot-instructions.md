# Copilot instructions

jasper-ssh is an SSH-authenticated proxy for the
[Jasper](https://github.com/cjmalloy/jasper) API, plus an optional Go
Kubernetes rollout controller. See `README.md` for runtime behavior and
environment variables.

## Repository layout

| Path | What it is |
|------|------------|
| `Dockerfile` | Server image: `nginx:*-alpine-slim` + OpenSSH. Copies the root `*.sh` scripts in. |
| `40-setup-users.sh` | nginx entrypoint hook: validates config, writes sshd/nginx config, starts sshd. |
| `healthcheck.sh`, `key-revocation.sh`, `shutdown.sh` | Health check, per-user key revocation, and Kubernetes `preStop` drain hook. |
| `controller/` | Go module for the rollout controller (`go.mod`, `go.sum`, tests, `Dockerfile`, `rbac.yaml`). |
| `compose.test.yml` | Docker Compose integration suite. |
| `tests/Dockerfile` | Alpine + bash test image; **copies** `tests/` in at build time. |
| `tests/run_tests.sh` | Integration test driver run by the `test-runner` service. |
| `tests/test_api_fetch.sh`, `tests/test_revocation_logging.sh`, `tests/test_shutdown_api_requirement.sh` | Standalone Bash unit tests for the shell scripts (not run by CI). |
| `tests/mock-kubernetes-curl.sh` | Mounted over `/usr/local/bin/curl` in `target-server` to fake the Kubernetes API. |

There is no Node.js/npm in this repo. The only lockfile is
`controller/go.sum`.

## Shell script conventions

- Root scripts and `tests/test_missing_config.sh` / `tests/mock-kubernetes-curl.sh`
  use `#!/bin/sh` and run under BusyBox `ash` in Alpine. They intentionally use
  `local` and other ash extensions. Do not rewrite them for strict POSIX.
- The other test scripts use `#!/usr/bin/env bash`.
- ShellCheck is not part of CI. `shellcheck -s sh` reports many expected
  `SC3043` (`local`) and similar warnings on the root scripts; treat it as
  advisory only.

## Controller (Go)

CI (`.github/workflows/controller-tests.yml`) runs from `controller/`:

```sh
cd controller
go test -v ./...
go vet ./...
go build ./...
```

- `go.mod` requires a newer Go than the sandbox usually has installed. The
  default `GOTOOLCHAIN=auto` downloads the right toolchain automatically; the
  first run takes about 1–2 minutes. Do not set `GOTOOLCHAIN=local` and do not
  lower the `go` directive in `go.mod`.
- `go build ./...` writes a `controller/controller` binary. It is gitignored;
  never commit it.
- If you change dependencies, run `go mod tidy` and commit `go.mod` and
  `go.sum` together. `go mod tidy -diff` must print nothing. Do not hand-edit
  `go.sum`.
- Format with `gofmt -l .` (must print nothing).
- Build the image with `docker build controller` (about 75 seconds when cold).

## Integration tests (Docker Compose)

Run exactly what CI (`.github/workflows/integration-tests.yml`) runs, from the
repository root:

```sh
docker compose -f compose.test.yml down -v   # always start from clean volumes
docker compose -f compose.test.yml up --build --wait \
  keygen http-backend config-tester target-server target-server-restart \
  shutdown-hook
docker compose -f compose.test.yml up --build --no-deps \
  --abort-on-container-exit --exit-code-from test-runner test-runner
docker compose -f compose.test.yml down -v
```

A clean run takes about 45 seconds when images are cached. It ends with 16
`[PASS]` lines between `=== TEST SUMMARY START ===` and
`=== TEST SUMMARY END ===`, then `test-runner-1 exited with code 0`.

### Pitfalls

1. **Always include `shutdown-hook` in the `--wait` list.** The test runner is
   started with `--no-deps`, so Compose will not start `shutdown-hook` for you.
   Without it, the first 11 tests pass and then
   `[FAIL] The shutdown hook did not start`.
2. **Run `down -v` before every rerun.** The suite is single-use. It shuts down
   sshd in `target-server` and leaves marker files such as `start-shutdown` in
   the `test-state` volume. The health check skips its checks while that marker
   exists, so `target-server` still reports *healthy* with no sshd. A rerun
   without `down -v` fails with
   `ssh: connect to host target-server port 22: Connection refused` and then
   `[FAIL] Tunnel on port 19001 did not proxy the backend`.
3. **Keep `--build` on both `up` commands.** The root scripts are copied into
   the server image, and `tests/` is copied into the test-runner image. Only
   `config-tester` and `http-backend` bind-mount `./tests`. Without `--build`,
   edits to those scripts are silently ignored.
4. **Debugging a failure:** before `down -v`, inspect the state with
   `docker compose -f compose.test.yml ps -a`,
   `docker compose -f compose.test.yml logs <service>`, and
   `docker compose -f compose.test.yml exec -T target-server sh -c 'ls /test-state; pgrep -a sshd'`.
5. **Alpine APK `TLS: unspecified error`:** the sandbox sometimes hits this
   while fetching an APK index during a build. It is intermittent; cold
   `--no-cache` builds can also succeed. If it happens, prebuild both Alpine
   images with host networking to populate the build cache, then rerun the
   normal Compose commands above:

   ```sh
   docker build --network=host -t jasper-ssh-integration-server .
   docker build --network=host -f tests/Dockerfile \
     -t jasper-ssh-integration-tests .
   ```

## Standalone shell unit tests

These scripts source the root scripts and stub their dependencies. They run on
the host with Bash in a few seconds. Run them after changing
`key-revocation.sh` or `shutdown.sh`:

```sh
bash tests/test_api_fetch.sh
bash tests/test_revocation_logging.sh
bash tests/test_shutdown_api_requirement.sh
```

## CI notes

- All workflows run on `ubuntu-24.04-arm`. The sandbox is `x86_64`, so the
  architecture differs, but the tests are architecture-independent.
- `docker-publish.yml` builds multi-arch images for both the server and the
  controller. It cannot be run locally because it pushes images; use
  `docker build .` and `docker build controller` instead.
- Dependabot updates Docker base images, GitHub Actions, and Go modules. The
  `k8s.io/*` modules are grouped. When updating a base image tag in
  `Dockerfile` or `tests/Dockerfile`, rerun the integration suite.

## Before finishing a change

- Shell or Dockerfile change: run the full Compose sequence above, and run the
  standalone shell unit tests.
- Controller change: run `go test ./...`, `go vet ./...`, and `gofmt -l .` in
  `controller/`.
- User-visible behavior or environment variable change: update `README.md`.
- Clean up with `docker compose -f compose.test.yml down -v`, and confirm
  that `git status` shows no stray artifacts.
