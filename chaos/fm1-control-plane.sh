#!/usr/bin/env bash
# FM1 -- control plane failure.
#
#   chaos/fm1-control-plane.sh destination-down [cluster]
#   chaos/fm1-control-plane.sh identity-down    [cluster]
#   chaos/fm1-control-plane.sh mirror-down      [cluster]
#   chaos/fm1-control-plane.sh restore          [cluster]
#
# Three sub-modes, all of which produce counterintuitive results. These are
# scale-to-zero rather than Chaos Mesh pod-kill, because a killed pod is
# rescheduled in seconds and we want a sustained outage to measure against.
#
# (a) destination-down
#     The proxy caches discovery, so existing traffic keeps flowing and every
#     dashboard stays green. But discovery is FROZEN: the mesh can no longer
#     learn that anything has changed. Kill a backend now and no failover
#     happens, because nothing can tell the proxies the endpoints went away.
#     The mesh is simultaneously "fine" and unable to react.
#
# (b) identity-down
#     Existing proxies hold valid certificates and keep working. But no NEW pod
#     can obtain one, so no pod can join the mesh. The DR consequence is sharp:
#     your failover plan requires scaling up, and scaling up requires identity.
#     Measure the real survival window from
#     control_identity_cert_expiration_timestamp_seconds rather than quoting the
#     nominal 24h lifetime.
#
# (c) mirror-down
#     The service-mirror controllers are the CROSS-CLUSTER control plane: one
#     per link, running in the cluster that sources the link, reconciling the
#     mirrored services and their EndpointSlices. This is the component a
#     multicluster DR exercise most obviously needs to test and the one this
#     repo had not tested.
#
#     Its blast radius is different from (a), and the difference is the point.
#     With destination down, the proxy's ENTIRE discovery is frozen -- local and
#     remote alike. With the mirrors down, destination is healthy and keeps
#     serving; what stops is the maintenance of cross-cluster membership. So the
#     cluster still learns about local change and stops learning about remote
#     change, which is a narrower and much less obvious failure.
#
#     FM4's recovery already implicated these controllers -- they came back
#     unmeshed after a region loss, meaning the components that maintain
#     federated membership were themselves outside the mesh.
#
#     The per-mode outcome is NOT asserted here, because the three exposure
#     modes maintain their endpoints by different paths and predicting which
#     ones freeze would be reasoning where this repo is supposed to measure.
#     The runner reports what each mode did and checks only what is structural:
#     that destination stayed up, and whether cross-cluster membership changed.
#
# WHAT THIS MEANS UNDER PROFILE=production
#
# Scale-to-zero removes EVERY replica, so under HA this is still a total control
# plane outage -- not "one replica of three fails", which is the event HA exists
# to absorb and which this does not measure. Keeping the fault identical across
# both profiles is deliberate: it is the only way the two arms compare, and the
# comparison is what the write-up is for. What changes between them is not the
# severity of the fault but the SHAPE of the failure -- under Ignore a recovering
# cluster silently admits unmeshed pods, under Fail it refuses to create them.
#
# So do not describe this as "an HA control plane failing". Describe it as what
# it is: a total control plane outage, run against both configurations. Whether
# HA absorbs a single-replica loss is a separate and still-unmeasured question.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl

ACTION="${1:-}"
# Default to central, not west: west hosts the observability stack, and breaking
# the control plane of the cluster you are watching from muddies the result. See
# the topology note in clusters/lib.sh.
TARGET="${2:-central}"
CTX="$(ctx "$TARGET")"

# Where the pre-injection replica counts are parked, so `restore` puts back what
# was actually there. The runner injects and restores in separate processes (see
# the cleanup trap in verify/fm1-verify.sh), so this cannot live in a variable.
STATE_DIR="${REPO_ROOT}/viz/data/fm1-${TARGET}"

# The control plane spans two namespaces: the core controllers live in
# `linkerd`, the service-mirror controllers in `linkerd-multicluster`. Derive it
# from the name rather than passing it at every call site -- scale and
# replicas_of both hardcoded `-n linkerd`, which would have made every
# mirror-down scale silently fail to find its deployment.
ns_of() {
  case "$1" in
    controller-*|linkerd-local-service-mirror) echo linkerd-multicluster ;;
    *)                                        echo linkerd ;;
  esac
}

scale() {
  kubectl --context="$CTX" -n "$(ns_of "$1")" scale deploy "$1" --replicas="$2" >/dev/null
}

# Current replica count for a control plane deployment, as SPECIFIED -- not as
# ready. A deployment mid-rollout would otherwise be recorded as smaller than it
# is and restored to that.
replicas_of() {
  kubectl --context="$CTX" -n "$(ns_of "$1")" get deploy "$1" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo ""
}

# Record what was there before breaking it.
#
# THE BUG THIS EXISTS TO PREVENT
#
# `restore` used to hardcode `--replicas=1`. Under PROFILE=production the
# control plane runs three replicas, so the first FM1 run would take
# destination 3 -> 0 and put back 1 -- silently dropping the cluster out of HA
# for every experiment that followed, while the run stayed labelled
# `production`. FM2, FM3 and FM4 would then have measured a single-replica
# control plane and reported it as the HA arm.
#
# No error, no warning, plausible output, wrong result. Exactly the failure
# class this repo keeps finding in its own instruments.
remember() {
  local dep n
  mkdir -p "$STATE_DIR"
  for dep in "$@"; do
    n="$(replicas_of "$dep")"
    # Never record 0. A component already at zero when the fault is injected
    # means an EARLIER run left it broken, and recording that would make the
    # damage permanent: restore would faithfully put back nothing, every run
    # after would record nothing, and the rig would stay degraded while every
    # restore reported success. Seen exactly once, on linkerd-local-service-mirror.
    if [ "${n:-0}" = "0" ]; then
      warn "  ${dep} is already at 0 replicas before injection.
     A previous run left it down. NOT recording 0 -- restore will use the
     profile default instead. Check the rig before trusting this run."
      continue
    fi
    if [ -n "$n" ]; then
      echo "$n" > "${STATE_DIR}/${dep}"
      log "  recorded ${dep} at ${n} replica(s) for restore"
    fi
  done
}

# Replicas to restore <deployment> to: what was recorded, else the profile's
# expected count, else 1. Never silently guesses without saying so.
restore_count() {
  local dep="$1" n
  n="$(cat "${STATE_DIR}/${dep}" 2>/dev/null || true)"
  if [ -n "$n" ]; then echo "$n"; return; fi
  if [ "${LINKERD_HA:-0}" = "1" ]; then n=3; else n=1; fi
  warn "no recorded replica count for ${dep}; restoring to ${n} from LINKERD_HA=${LINKERD_HA:-0}"
  echo "$n"
}

case "$ACTION" in
  destination-down)
    remember linkerd-destination
    log "FM1a: scaling linkerd-destination to 0 in '${TARGET}'"
    scale linkerd-destination 0
    ok "  destination controller stopped"
    cat <<EOF

Discovery is now frozen in '${TARGET}'. Existing traffic should continue.

The point of this experiment is what happens NEXT. While discovery is down,
remove some endpoints and watch whether failover occurs:

  kubectl --context=k3d-east -n ${APP_NS} scale deploy app --replicas=0
  verify/watch.sh          # does west stop sending to east's now-dead pods?

Restore with: chaos/fm1-control-plane.sh restore ${TARGET}
EOF
    ;;

  mirror-down)
    # Discovered rather than hardcoded: which controllers exist depends on which
    # links this cluster SOURCES, which comes from the topology table and the
    # GATEWAY_LINKS list in clusters/05-multicluster.sh. central sources
    # controller-west, controller-east and controller-east-gw; east sources no
    # gateway link at all. Hardcoding a name here would silently no-op on a
    # cluster whose link set is different, and a no-op fault is the worst
    # possible experiment -- it looks like a result.
    # Both the per-link controllers AND the local service mirror.
    #
    # The first run of this experiment killed only `controller-*` and the
    # federated pool still moved 9 -> 8, because the component that actually
    # owns federated membership was left running. Confirmed from its own args
    # and its own logs on a live rig:
    #
    #   -local-mirror -federated-service-selector=mirror.linkerd.io/federated=member
    #   "RemoteServiceJoinsFederatedService" -> "Updating federated service dr-demo/app-federated"
    #
    # So a fault that discovers its targets by the `controller-` prefix alone is
    # a PARTIAL fault, and the run that produced it was not measuring what its
    # name claimed. linkerd-gateway is still deliberately excluded: it is the
    # data path for gateway mirrors, not the cross-cluster control plane, and
    # taking it down would confound this experiment with FM2's.
    controllers="$(kubectl --context="$CTX" -n linkerd-multicluster get deploy \
      -o name 2>/dev/null | sed 's|^deployment.apps/||' \
      | grep -E '^(controller-|linkerd-local-service-mirror$)' || true)"

    [ -n "$controllers" ] || die "no service-mirror controllers found in '${TARGET}'.
     Expected deployments named controller-<link> in linkerd-multicluster.
     Without them this fault injects nothing and the run would report a clean
     pass on an experiment that never happened."

    # shellcheck disable=SC2086
    remember $controllers

    log "FM1c: scaling the service-mirror controllers to 0 in '${TARGET}'"
    for dep in $controllers; do
      scale "$dep" 0
      ok "  ${dep} stopped"
    done

    cat <<EOF

The cross-cluster control plane is now down in '${TARGET}', and its LOCAL
control plane is untouched -- destination and identity are both still running.
That is the whole distinction from FM1a.

Mirrored services and their EndpointSlices are no longer being reconciled, so
membership changes in other clusters cannot arrive. Existing traffic should be
unaffected, and nothing should error.

  linkerd --context=${CTX} multicluster gateways
  kubectl --context=${CTX} -n linkerd-multicluster get links
  kubectl --context=${CTX} -n ${APP_NS} get endpointslices

Restore with: chaos/fm1-control-plane.sh restore ${TARGET}
EOF
    ;;

  identity-down)
    remember linkerd-identity
    log "FM1b: scaling linkerd-identity to 0 in '${TARGET}'"
    scale linkerd-identity 0
    ok "  identity controller stopped"

    log "current certificate headroom across the data plane"
    bash "${REPO_ROOT}/verify/cert-headroom.sh" "$TARGET" 2>/dev/null || true

    cat <<EOF

Identity is down in '${TARGET}'. Existing proxies keep their certificates.

The DR-relevant test is whether you can still scale up -- which every failover
plan assumes you can:

  kubectl --context=${CTX} -n ${APP_NS} scale deploy app --replicas=6
  kubectl --context=${CTX} -n ${APP_NS} get pods -w

Restore with: chaos/fm1-control-plane.sh restore ${TARGET}
EOF
    ;;

  restore)
    log "FM1 restore: bringing the control plane back in '${TARGET}'"
    scale linkerd-destination "$(restore_count linkerd-destination)"
    scale linkerd-identity "$(restore_count linkerd-identity)"
    kubectl --context="$CTX" -n linkerd rollout status deploy/linkerd-destination --timeout=180s >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n linkerd rollout status deploy/linkerd-identity --timeout=180s >/dev/null 2>&1 || true

    # Restore every multicluster component we recorded. Driven off the recorded
    # state rather than a live listing, so a controller that FM1c scaled to zero
    # is still restored even though it is currently reporting zero replicas.
    #
    # The glob must match everything `remember` writes, not just controller-*.
    # It did not, and the first corrected FM1c run left
    # linkerd-local-service-mirror at 0/0 -- the fault restored three of its four
    # components and reported "control plane restored". Silently leaving the rig
    # degraded is worse than failing to restore it loudly, because the next
    # experiment inherits it as a baseline.
    for f in "${STATE_DIR}"/controller-* "${STATE_DIR}"/linkerd-local-service-mirror; do
      [ -e "$f" ] || continue
      dep="$(basename "$f")"
      scale "$dep" "$(restore_count "$dep")"
      kubectl --context="$CTX" -n linkerd-multicluster rollout status "deploy/${dep}" \
        --timeout=180s >/dev/null 2>&1 || true
      ok "  ${dep} restored"
    done

    ok "  control plane restored"
    ;;

  *)
    die "usage: fm1-control-plane.sh <destination-down|identity-down|mirror-down|restore> [cluster]"
    ;;
esac
