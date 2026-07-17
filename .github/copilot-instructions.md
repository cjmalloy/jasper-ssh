# Copilot instructions

If an Alpine-based Docker build reports `TLS: unspecified error` while fetching
an APK index, retry the build with host networking:

```sh
docker build --network=host -t <image-name> .
```

For the integration images, use the same network mode with the relevant
Dockerfile. Do not switch Alpine repositories to HTTP or commit Docker daemon
DNS changes as a workaround.
