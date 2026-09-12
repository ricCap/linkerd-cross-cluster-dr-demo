#!/usr/bin/env bash
# FM4 -- region failure.
#
#   chaos/fm4-region-loss.sh fail    [region]
#   chaos/fm4-region-loss.sh restore [region]
#
# Default region is region-a, which contains BOTH east and central. That is why
# the topology puts two clusters in one region: otherwise "region failure" is
# just a cluster failure with a grander name.
#
# west is the survivor, and it is where the observability stack lives, so this
# experiment can be watched while it happens. That is deliberate and it was not
# always true -- see the topology note in clusters/lib.sh.
#
# Two things are being tested at once, and the second is the interesting one:
#
#   1. Can the surviving region absorb 100% of traffic, and how fast?
#
#   2. The service-mirror controllers that maintain federated membership were
#      running in the clusters that just died. So did the SURVIVOR lose the
#      ability to update membership, even though its data plane is fine?
#
#      This is the control-plane vs data-plane distinction that DR plans
#      routinely conflate. A cluster can be perfectly capable of serving traffic
#      while being completely unable to learn about topology changes.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need docker kubectl

ACTION="${1:-}"
REGION="${2:-region-a}"

targets() { clusters_in_region "$REGION"; }

# A region name that matches no cluster yields an empty target list, and every
# loop below then iterates nothing: the run logs "failing region" and reports
# success having partitioned no cluster at all. Same silent-zero-target failure
# the FM3 brownout guards against -- see SHORTCOMINGS section 16.
[ -n "$(targets)" ] \
  || die "region '${REGION}' contains no clusters. Known regions: $(regions | tr '\n' ' ')"

nodes_of() {
  docker ps -a --format '{{.Names}}' \
    | grep -E "^k3d-${1}-(server|agent)-[0-9]+$" | sort
}

case "$ACTION" in
  fail)
    log "FM4: failing region '${REGION}' -- clusters: $(targets | tr '\n' ' ')"
    survivors="$(for c in $(clusters); do
      echo "$(targets)" | grep -qx "$c" || echo "$c"
    done)"
    log "  survivors: $(echo "$survivors" | tr '\n' ' ')"

    # Record addresses first so the reattach can restore them exactly.
    # shellcheck disable=SC2046
    save_node_ips $(targets)

    # Partition rather than stop: a region does not shut down politely.
    for c in $(targets); do
      for n in $(nodes_of "$c"); do
        docker network disconnect -f "$DOCKER_NET" "$n" 2>/dev/null \
          && ok "  cut ${n}" || warn "  ${n} already cut"
      done
    done

    cat <<EOF

Region '${REGION}' is now unreachable. Things worth looking at from a survivor:

  # does the data plane keep serving?
  verify/watch.sh

  # can the survivor still see federated membership change?
  kubectl --context=k3d-<survivor> -n linkerd-multicluster get links
  kubectl --context=k3d-<survivor> -n linkerd-multicluster logs deploy/controller-<dead> -c controller --tail=20
EOF
    ;;

  restore)
    log "FM4: restoring region '${REGION}'"
    for c in $(targets); do
      for n in $(nodes_of "$c"); do
        restore_node_ip "$n"
        docker start "$n" >/dev/null 2>&1 || true
        ok "  reattached ${n} on its original address"
      done
    done

    # Reattaching to a Docker network reassigns addresses in reattach order, so
    # nodes come back on DIFFERENT IPs than they left with. k3s then wedges --
    # its API cert and internal config reference the old address -- and the API
    # server never returns, no matter how long you wait for it.
    #
    # Observed twice: FM2 moved east-server-0 .7 -> .9, and FM4 moved
    # west-server-0 .3 -> .5 and central-server-0 .11 -> .13, wedging both
    # clusters for 17 minutes until killed. Waiting longer does not help; the
    # cluster has to be cycled so k3s re-initialises on its new address.
    log "cycling clusters so k3s re-initialises on stable addressing"
    for c in $(targets); do
      k3d cluster stop "$c" >/dev/null 2>&1 || true
      k3d cluster start "$c" >/dev/null 2>&1 || warn "  k3d cluster start '${c}' reported an error"
      ok "  cycled ${c}"
    done

    # Reattaching does not revive the kubelet -- agents come back NotReady and
    # stay that way. Restart the containers so they re-register; pinned
    # addresses survive a restart.
    log "restarting node containers so kubelets re-register"
    for c in $(targets); do
      for n in $(nodes_of "$c"); do docker restart "$n" >/dev/null 2>&1 || true; done
    done

    log "waiting for API servers"
    for c in $(targets); do
      api_up() { kubectl --context="$(ctx "$1")" cluster-info >/dev/null 2>&1; }
      retry 18 10 api_up "$c" || warn "  '${c}' API did not return within 3m"
    done

    # Routes do not survive container restart or network reattachment.
    log "reinstalling the cross-cluster route mesh"
    bash "${REPO_ROOT}/clusters/02-routes.sh" 2>&1 | grep -E 'ok |warn' || true

    # Same API-address drift problem as FM2: re-link unconditionally here, since
    # two clusters moved and checking each pair is not worth the code.
    log "re-establishing links"
    bash "${REPO_ROOT}/clusters/05-multicluster.sh" >/dev/null 2>&1 \
      && ok "links re-established" || warn "re-linking reported an error"
    ;;

  *)
    die "usage: fm4-region-loss.sh <fail|restore> [region]"
    ;;
esac
