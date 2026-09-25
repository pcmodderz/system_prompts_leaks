#!/usr/bin/env bash
# Runs `swift <args>` for the Hearth package inside a Linux Swift container.
# Used to build and test HearthCore on machines without a Swift toolchain.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${HEARTH_SWIFT_IMAGE:-hearth-swift}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" - <<'DOCKERFILE'
FROM swift:6.1-noble
RUN apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi
PROXY_ARGS=()
if [[ -n "${HTTPS_PROXY:-}" ]]; then PROXY_ARGS=(-e "http_proxy=$HTTPS_PROXY" -e "https_proxy=$HTTPS_PROXY"); fi
exec docker run --rm --network host "${PROXY_ARGS[@]}" -v "$HERE:/hearth" -w /hearth "$IMAGE" swift "$@"
