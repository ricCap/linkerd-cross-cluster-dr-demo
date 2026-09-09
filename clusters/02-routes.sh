#!/usr/bin/env bash
# Install the static route mesh between node containers.
#
# Ingredient 3 of 3 for the flat network, and the only genuinely non-obvious
# one. Flannel routes pod traffic *within* its own cluster and knows nothing
# about any other cluster's pod CIDR. So for every ordered pair of nodes that
# live in different clusters we install, inside the source node's container:
#
#     ip route add <dest node pod CIDR> via <dest node internal IP>
#
# A packet from a pod bound for 10.22.1.5 then hits its node's routing table,
# finds the route, crosses the shared Docker bridge to the peer node's IP, and
# that node's flannel delivers it to the local pod.
#
# Upstream this is a 2-cluster nested loop in BuoyantIO/k3d-multicluster-
# playground (deploy-p2p-clusters.sh). Here it is generalised to N clusters:
# the mesh is O(nodes^2) over cross-cluster pairs, 54 directed routes at 3x3.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need docker kubectl jq

# Collect every node in every cluster as: cluster<TAB>container<TAB>podCIDR<TAB>ip
node_table() {
  local name
  for name in $(clusters); do
    kubectl --context="$(ctx "$name")" get node -o json \
      | jq -r --arg c "$name" '
          .items[]
          | [$c,
             .metadata.name,
             .spec.podCIDR,
             (.status.addresses[] | select(.type == "InternalIP") | .address)]
          | @tsv'
  done
}

TABLE="$(node_table)"
[ -n "$TABLE" ] || die "no nodes found -- are the clusters up?"

node_count="$(echo "$TABLE" | wc -l | tr -d ' ')"
log "found ${node_count} nodes across $(clusters | wc -l | tr -d ' ') clusters"

# Sanity check: every node must have a podCIDR, and no two clusters may share
# a pod CIDR prefix. Catching this here is far cheaper than debugging silent
# blackholed traffic later.
if echo "$TABLE" | awk -F'\t' '{print $3}' | grep -q '^null$'; then
  die "a node has no .spec.podCIDR -- cluster is not fully initialised yet"
fi

dupes="$(echo "$TABLE" | awk -F'\t' '{print $3}' | sort | uniq -d)"
[ -z "$dupes" ] || die "duplicate pod CIDRs across clusters: ${dupes}"

added=0
skipped=0

while IFS=$'\t' read -r s_cluster s_node s_cidr s_ip; do
  [ -n "$s_cluster" ] || continue
  while IFS=$'\t' read -r d_cluster d_node d_cidr d_ip; do
    [ -n "$d_cluster" ] || continue
    # Only cross-cluster pairs: flannel already handles intra-cluster routing.
    [ "$s_cluster" != "$d_cluster" ] || continue

    # `replace` rather than `add` so re-running the script is idempotent
    # instead of failing with "File exists".
    if docker exec "$s_node" ip route replace "$d_cidr" via "$d_ip" 2>/dev/null; then
      added=$((added + 1))
    else
      warn "could not add route on ${s_node}: ${d_cidr} via ${d_ip}"
      skipped=$((skipped + 1))
    fi
  done <<< "$TABLE"
done <<< "$TABLE"

ok "installed ${added} cross-cluster routes (${skipped} failed)"
[ "$skipped" -eq 0 ] || die "some routes failed to install"

# CoreDNS in each cluster needs to resolve the *other* clusters' API servers by
# the name embedded in their kubeconfig. k3d wires each cluster's API to a
# host-side port; the service-mirror controller in cluster A talks to cluster
# B's API, so it needs a route to the node IP -- which the mesh above provides.
log "route table sample (from first node)"
first_node="$(echo "$TABLE" | head -1 | awk -F'\t' '{print $2}')"
docker exec "$first_node" ip route | grep -E '^10\.' || true

cat <<'EOF'

Next: verify/flat-network.sh proves pod-to-pod reachability across all cluster
pairs. Routes existing is not the same as traffic flowing -- run the check.
EOF
