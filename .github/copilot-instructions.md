# Copilot instructions

If an Alpine-based Docker build reports `TLS: unspecified error` while fetching
an APK index, retry the affected image build with host networking. For the
integration suite, first build both Alpine-based Dockerfiles this way to
populate the build cache, then run the normal Compose commands:

```sh
docker build --network=host -t jasper-ssh-integration-server .
docker build --network=host -f tests/Dockerfile \
  -t jasper-ssh-integration-tests .
docker compose -f compose.test.yml up --build --wait \
  keygen http-backend config-tester target-server target-server-restart
docker compose -f compose.test.yml up --build --no-deps \
  --abort-on-container-exit --exit-code-from test-runner test-runner
docker compose -f compose.test.yml down -v
```
