#!/usr/bin/env bash
# FM2 -- cluster failure.
#
#   chaos/fm2-cluster-loss.sh graceful [cluster]   stop the nodes (orderly)
#   chaos/fm2-cluster-loss.sh hard     [cluster]   cut it off the network
#   chaos/fm2-cluster-loss.sh restore  [cluster]   bring it back
#
# No in-cluster chaos tool can kill its own cluster, so this operates at the
# k3d/Docker layer instead of through Chaos Mesh.
#
# The two variants are genuinely different failures and are expected to produce
# different convergence times, which is itself a result worth reporting:
#
#   graceful  `k3d node stop` -- containers stop, TCP connections are refused
#             promptly, and the kubelet has a chance to deregister. This is a
#             clean shutdown: closer to a planned drain than a disaster.
#
#   hard      `docker network disconnect` -- packets are blackholed. Nothing is
#             refused, connections hang until timeout. This is what a real
#             regional network event looks like, and it is the honest test of
#             failover timing.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need docker k3d

ACTION="${1:-}"
TARGET="${2:-east}"

nodes_of() {
  docker ps -a --format '{{.Names}}' \
    | grep -E "^k3d-${1}-(server|agent)-[0-9]+$" | sort
}

case "$ACTION" in
  graceful)
    log "FM2 graceful: stopping all nodes in '${TARGET}'"
    # A plain docker stop/start also loses the address -- the first run of this
    # experiment moved east-server-0 from .7 to .9 and swapped it with an agent.
    # Record addresses here too, not just on the hard partition.
    save_node_ips "$TARGET"
    for n in $(nodes_of "$TARGET"); do
      docker stop "$n" >/dev/null && ok "  stopped ${n}"
    done
    ;;

  hard)
    log "FM2 hard: disconnecting '${TARGET}' from the ${DOCKER_NET} network"
    # Record addresses first so the reattach can restore them exactly -- see
    # save_node_ips in clusters/lib.sh for why this matters.
    save_node_ips "$TARGET"
    for n in $(nodes_of "$TARGET"); do
      docker network disconnect -f "$DOCKER_NET" "$n" 2>/dev/null \
        && ok "  disconnected ${n}" \
        || warn "  ${n} already disconnected"
    done
    ;;

  restore)
    log "FM2 restore: bringing '${TARGET}' back"
    for n in $(nodes_of "$TARGET"); do
      restore_node_ip "$n"
      docker start "$n" >/dev/null 2>&1 || true
      ok "  reattached ${n} on its original address"
    done

    # Reconnecting to a Docker network hands out addresses in whatever order the
    # containers happen to reattach, so nodes can come back on DIFFERENT IPs than
    # they left with. Observed here: east-server-0 went 172.28.0.7 -> .9 and
    # swapped with an agent. k3s then wedges (its API cert and internal config
    # reference the old address) and every Link, which pins the API address at
    # creation time, is now pointing at an agent node.
    #
    # `k3d cluster stop && start` re-initialises the cluster and restores k3d's
    # deterministic address assignment. Raw `docker start` does not.
    # Only cycle the cluster if the address actually moved. With addresses
    # pinned on reattach this should not happen, and skipping the cycle takes
    # minutes off recovery.
    restored_ip="$(docker inspect "k3d-${TARGET}-server-0" \
      -f "{{(index .NetworkSettings.Networks \"${DOCKER_NET}\").IPAddress}}" 2>/dev/null)"
    expected_ip="$(awk -v n="k3d-${TARGET}-server-0" '$1 == n {print $2; exit}' "$(ip_state_file)" 2>/dev/null || true)"
    if [ -n "$expected_ip" ] && [ "$restored_ip" != "$expected_ip" ]; then
      warn "address drifted (${expected_ip} -> ${restored_ip}); cycling the cluster"
      k3d cluster stop "$TARGET" >/dev/null 2>&1 || true
      k3d cluster start "$TARGET" >/dev/null 2>&1 || warn "k3d cluster start reported an error"
    else
      ok "address preserved (${restored_ip}) -- no cluster cycle needed"
    fi

    # Reattaching restores connectivity but does not revive the kubelet: agent
    # nodes come back NotReady and stay that way (observed: still NotReady after
    # 120s). The kubelet has to be restarted to re-register with the API server.
    # Pinned addresses survive a container restart, so this is cheap.
    log "restarting node containers so kubelets re-register"
    for n in $(nodes_of "$TARGET"); do
      docker restart "$n" >/dev/null 2>&1 || true
    done

    log "waiting for the API server to answer again"
    api_up() { kubectl --context="$(ctx "$TARGET")" cluster-info >/dev/null 2>&1; }
    retry 30 10 api_up || warn "'${TARGET}' API server did not come back within 5m"

    # Routes live in the node containers' routing tables and do not survive a
    # container restart. Without this the cluster comes back but stays
    # unreachable pod-to-pod, which looks like a much scarier failure than it is.
    log "reinstalling the cross-cluster route mesh"
    bash "${REPO_ROOT}/clusters/02-routes.sh" 2>&1 | grep -E 'ok |warn' || true

    # A restarted container can come back on a different address. Every Link
    # pins the target's API server address at creation time, so if the IP moved,
    # the service-mirror controllers in the OTHER clusters are now pointing at
    # nothing -- and federated membership will never recover, no matter how
    # healthy the restored cluster is.
    #
    # This is not a k3d quirk to be papered over. It is the DR lesson: recovery
    # is not "bring the cluster back", it is "bring the cluster back AND
    # re-establish the links". Detect it loudly.
    log "checking whether the API address the Links point at is still valid"
    current_ip="$(kubectl --context="$(ctx "$TARGET")" get node "k3d-${TARGET}-server-0" \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"

    drifted=0
    for src in $(clusters); do
      [ "$src" != "$TARGET" ] || continue
      linked_ip="$(kubectl --context="$(ctx "$src")" -n linkerd-multicluster \
        get secret "cluster-credentials-${TARGET}" \
        -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null \
        | sed -n 's|.*server: https://\([0-9.]*\):6443.*|\1|p' | head -1)"
      if [ -n "$linked_ip" ] && [ "$linked_ip" != "$current_ip" ]; then
        warn "  ${src} -> ${TARGET}: link points at ${linked_ip}, cluster is now at ${current_ip}"
        drifted=1
      fi
    done

    if [ "$drifted" = "1" ]; then
      warn "API address drifted. Re-linking (this is what a real runbook must do)."
      bash "${REPO_ROOT}/clusters/05-multicluster.sh" >/dev/null 2>&1 \
        && ok "links re-established" \
        || warn "re-linking failed"
    else
      ok "API address unchanged (${current_ip}) -- links should recover on their own"
    fi
    ;;

  *)
    die "usage: fm2-cluster-loss.sh <graceful|hard|restore> [cluster]"
    ;;
esac
