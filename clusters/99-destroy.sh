#!/usr/bin/env bash
# Tear the whole environment down.
#
# Certificates are preserved by default: regenerating the trust anchor on every
# rebuild would make "did the anchor change?" ambiguous, which is the one
# question FM5 is about. Pass FORCE_CERTS=1 to clusters/03-certs.sh to rotate
# them deliberately.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need docker k3d

# The host-side relays first, and BEFORE the network removal below.
#
# task up starts two containers that are not k3d nodes -- dr-expose-grafana
# (socat onto Grafana's nodePort) and dr-expose-viz (the status page) -- and
# nothing here removed them. Two consequences, the second worse than the first:
# they were left running after every teardown, and because dr-expose-grafana is
# ATTACHED TO dr-net, `docker network rm` then failed. The script warned
# "network still in use, left in place" and exited 0, so a later `task up`
# quietly reused a network it believed it had just created.
#
# Runs even if the clusters are already gone: `12-expose.sh down` also deletes
# the nodePort Service, which needs an API server that may not be there, so its
# failure must not stop the teardown.
log "removing host-side relays"
bash "${REPO_ROOT}/clusters/12-expose.sh" down 2>/dev/null | sed 's/^/  /' || true

for name in $(clusters); do
  if k3d cluster list "$name" >/dev/null 2>&1; then
    log "deleting cluster '${name}'"
    k3d cluster delete "$name" >/dev/null 2>&1 || warn "failed to delete '${name}'"
  fi
done

if [ "${KEEP_NETWORK:-0}" != "1" ]; then
  if docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
    log "removing docker network '${DOCKER_NET}'"
    if ! docker network rm "$DOCKER_NET" >/dev/null 2>&1; then
      # Name what is holding it. "still in use" with no subject is the message
      # that let this go unnoticed for as long as it did.
      warn "network '${DOCKER_NET}' still in use, left in place. Attached:
     $(docker network inspect "$DOCKER_NET" \
         --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)"
    fi
  fi
fi

rm -rf "${REPO_ROOT}/clusters/.generated"

ok "environment destroyed (certs kept in ${REPO_ROOT}/certs)"
