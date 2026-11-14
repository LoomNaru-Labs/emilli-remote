#!/usr/bin/env bash
# Builds the patched hbbs image: upstream rustdesk-server tag 1.1.16 + 0001-accounts-gate.patch.
#   bash deploy/rustdesk-accounts/hbbs/build.sh            # deployable image (upstream release profile)
#   PROFILE=fast bash deploy/rustdesk-accounts/hbbs/build.sh   # quick local iteration, no LTO
# Prints the image ID; the compose file pins that ID.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))"
PROFILE="${PROFILE:-release}"
# accounts2 (REMOTE-EASY-3B): the peer report also carries the public key the PC registered.
TAG="${TAG:-emilli/rustdesk-hbbs:1.1.16-accounts2}"
[ "$PROFILE" = fast ] && TAG="${TAG}-fast"
DOCKER_BUILDKIT=1 docker build --build-arg PROFILE="$PROFILE" -t "$TAG" "$HERE"
docker image inspect "$TAG" --format '{{.Id}}'
