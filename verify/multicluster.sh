#!/usr/bin/env bash
# Functional gate for the multicluster setup.
#
# This is the check that actually matters. The host-side `linkerd multicluster
# check` cannot validate credentials in this environment (the API addresses are
# Docker-network IPs only containers can reach), so instead we assert the thing
# we actually care about: do the three exposure modes resolve to the right
# endpoints, in the right numbers, from the right clusters?
#
# The endpoint COUNT assertion is not pedantry. A federated service silently
# double-counts a cluster if more than one Link to that cluster carries the
# default federated-service-selector -- you get 12 endpoints instead of 9, the
# baseline shifts from 33/33/33 to 25/50/25, and every traffic-distribution
# number in the experiments is quietly wrong. Counting catches it; eyeballing
# does not.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl linkerd jq

PORT=9898
fails=0

# Endpoint IPs for a service, one per line.
endpoints_of() {
  linkerd --context="$(ctx "$1")" diagnostics endpoints "${2}.${APP_NS}.svc.cluster.local:${PORT}" 2>/dev/null \
    | awk 'NR > 1 && $2 != "" { print $2 }'
}


check_service() {
  local from="$1" svc="$2" expect_total="$3" expect_clusters="$4" desc="$5"

  local eps total
  eps="$(endpoints_of "$from" "$svc")"
  total="$(echo "$eps" | grep -c . || true)"

  printf '\n%s\n' "--- ${svc} (from ${from}) -- ${desc}"

  if [ "$total" -eq 0 ]; then
    printf '  \033[1;31mFAIL\033[0m no endpoints at all\n'
    fails=$((fails + 1))
    return
  fi

  # Distribution by owning cluster.
  local dist="" c n
  for c in $(clusters); do
    n="$(echo "$eps" | while read -r ip; do [ -n "$ip" ] && cluster_of_ip "$ip"; done | grep -c "^${c}$" || true)"
    [ "$n" -gt 0 ] && dist="${dist}${c}=${n} "
  done
  printf '  endpoints: %s total  [%s]\n' "$total" "${dist% }"

  # Duplicate IPs are the signature of double-counted federation members.
  local dupes
  dupes="$(echo "$eps" | sort | uniq -d | grep -c . || true)"
  if [ "$dupes" -ne 0 ]; then
    printf '  \033[1;31mFAIL\033[0m %s duplicate endpoint IP(s) -- a cluster is being counted twice.\n' "$dupes"
    printf '         Check that only ONE Link per target cluster carries the\n'
    printf '         federated-service-selector (see clusters/05-multicluster.sh).\n'
    fails=$((fails + 1))
    return
  fi

  local n_clusters
  n_clusters="$(echo "$eps" | while read -r ip; do [ -n "$ip" ] && cluster_of_ip "$ip"; done | sort -u | grep -c . || true)"

  if [ "$total" -ne "$expect_total" ]; then
    printf '  \033[1;31mFAIL\033[0m expected %s endpoints, got %s\n' "$expect_total" "$total"
    fails=$((fails + 1))
  elif [ "$n_clusters" -ne "$expect_clusters" ]; then
    printf '  \033[1;31mFAIL\033[0m expected endpoints from %s cluster(s), got %s\n' "$expect_clusters" "$n_clusters"
    fails=$((fails + 1))
  else
    printf '  \033[1;32mPASS\033[0m\n'
  fi
}

log "verifying the three cross-cluster exposure modes"

# federated: 3 pods x 3 clusters, every cluster represented, no duplicates.
check_service west app-federated 9 3 "federated union across all clusters"

# flat mirror: resolves to the TARGET cluster's pods only.
check_service west app-flat-east    3 1 "flat mirror (remote discovery) of east"
check_service west app-flat-central 3 1 "flat mirror (remote discovery) of central"

# gateway mirror: resolves to the GATEWAY, not to the backing pods, so we assert
# that it resolves rather than pinning a count -- and we assert it from every
# cluster that sources a gateway link, because an experiment can only measure a
# mode its observing cluster can resolve.
#
# The second assertion is the one worth explaining. A gateway mirror's endpoint
# is a node address on the Docker network, not a pod IP, so cluster_of_ip has to
# fall back to the node table to attribute it. If that table is missing the
# address files as "other": every gateway request then attributes to a cluster
# that does not exist, and per-cluster distribution and convergence figures for
# gateway mode are silently wrong rather than absent. Gate it here, once.
check_gateway_mirror() {
  local from="$1" svc="$2" eps ip owner

  printf '\n%s\n' "--- ${svc} (from ${from}) -- gateway mirror"
  eps="$(endpoints_of "$from" "$svc")"

  if [ -z "$eps" ]; then
    printf '  \033[1;31mFAIL\033[0m gateway mirror has no endpoints\n'
    fails=$((fails + 1))
    return
  fi
  printf '  resolves via gateway to: %s\n' "$(echo "$eps" | tr '\n' ' ')"

  ip="$(echo "$eps" | head -1)"
  owner="$(cluster_of_ip "$ip")"
  if [ "$owner" = "other" ]; then
    printf '  \033[1;31mFAIL\033[0m %s does not resolve to a cluster.\n' "$ip"
    printf '         The gateway address is a NODE address, so cluster_of_ip needs\n'
    printf '         the table 05-multicluster.sh writes via save_node_ips. Without\n'
    printf '         it, every gateway-mode request attributes to "other" and any\n'
    printf '         distribution or convergence number for this mode is wrong.\n'
    fails=$((fails + 1))
    return
  fi

  printf '  attributes to cluster: %s\n' "$owner"
  printf '  \033[1;32mPASS\033[0m\n'
}

for src in $(clusters); do
  gw="$(gateway_target_for "$src")"
  if [ -n "$gw" ]; then check_gateway_mirror "$src" "$gw"; fi
done

echo
if [ "$fails" -ne 0 ]; then
  die "${fails} multicluster check(s) failed"
fi
ok "all three exposure modes resolve correctly, from every cluster that sources them"
