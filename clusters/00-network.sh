#!/usr/bin/env bash
# Create the shared Docker network that all three k3d clusters attach to.
#
# This is ingredient 1 of 3 for the flat network. Every k3s node container sits
# on the same user-defined bridge, so node-to-node reachability is free. What is
# *not* free is pod-to-pod reachability -- see 02-routes.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need docker

if docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
  existing="$(docker network inspect "$DOCKER_NET" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  log "docker network '$DOCKER_NET' already exists (subnet ${existing})"
else
  log "creating docker network '$DOCKER_NET' (${DOCKER_NET_SUBNET})"
  # An explicit subnet keeps node IPs deterministic across teardown/rebuild,
  # which matters because the route mesh and the chaos scripts reference them.
  docker network create \
    --driver bridge \
    --subnet "$DOCKER_NET_SUBNET" \
    "$DOCKER_NET" >/dev/null
fi

ok "network ready: $DOCKER_NET"
