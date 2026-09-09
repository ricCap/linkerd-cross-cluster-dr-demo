#!/usr/bin/env bash
# Read-only checks that settle claims the write-up currently makes on reasoning.
#
#   verify/preflight-claims.sh [cluster]
#
# Injects nothing and changes nothing. Every check here exists because the post
# asserts something that was never measured, and each one is cheap enough that
# asserting it instead of measuring it was never justified.
#
# Run it on a healthy rig, before any fault.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl linkerd

OBSERVER="${1:-west}"
CTX="$(ctx "$OBSERVER")"

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- 1. Is Topology Aware Routing even available across a cluster boundary? --
#
# THE CLAIM THIS TESTS
#
# The write-up says "Topology Aware Routing keys off topology, not load, so a
# slow-but-healthy zone is still, to TAR, the right place to send traffic." That
# sentence is reasoned, not measured: no TAR arm was ever run, and the OSS
# comparison arm spread zone-agnostically -- which means TAR was OFF and what
# was actually measured is HAZL against no zone awareness at all.
#
# There is a sharper and much cheaper question underneath it. Topology hints are
# computed by the in-cluster EndpointSlice controller from the zone labels on
# the NODES backing each endpoint. A mirrored EndpointSlice points at pod IPs in
# another cluster, on nodes that do not exist in this cluster's node registry.
# If the controller has no node to read a zone from, it has nothing to write a
# hint from -- and TAR would be structurally unavailable across the boundary,
# regardless of configuration.
#
# That is a one-command question and it either kills the TAR claim or replaces
# it with a better one. Either way the post stops asserting it.
banner "1. topology hints on LOCAL vs MIRRORED EndpointSlices, in '${OBSERVER}'"

printf '\n  %-42s %-8s %-10s %s\n' SLICE MIRRORED ENDPOINTS 'HINTS PRESENT'
printf -- '  ---------------------------------------------------------------------------\n'

kubectl --context="$CTX" -n "$APP_NS" get endpointslices \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.mirror\.linkerd\.io/mirrored-service}{"|"}{range .endpoints[*]}{.hints.forZones[*].name}{","}{end}{"|"}{.endpoints}{"\n"}{end}' \
  2>/dev/null | while IFS='|' read -r name mirrored hints eps; do
    [ -n "$name" ] || continue
    n_eps="$(echo "$eps" | grep -o '"addresses"' | wc -l | tr -d ' ')"
    if echo "$hints" | grep -q '[a-z]'; then h="yes: ${hints%,}"; else h="NO"; fi
    printf '  %-42s %-8s %-10s %s\n' "$name" "${mirrored:-no}" "$n_eps" "$h"
  done

cat <<'EOF'

  Read it this way. A local slice with hints and a mirrored slice without is the
  finding: zone-aware routing that Kubernetes can compute inside a cluster and
  cannot compute across one. If BOTH are empty, hints are simply not enabled
  here (no service.kubernetes.io/topology-mode=Auto and no
  spec.trafficDistribution), and this run says nothing about TAR either way --
  which is itself worth knowing before the post claims otherwise.
EOF

# SETTLED 2026-09-08: TAR cannot reach cross-cluster traffic at all.
#
# Enabling spec.trafficDistribution=PreferClose on a LOCAL service produces
# hints immediately, so the mechanism works here. But the cross-cluster services
# are selector-less ClusterIP Services carrying
# multicluster.linkerd.io/remote-discovery -- Kubernetes creates no
# EndpointSlices for them, and destination resolves them across the Link at
# request time. The only mirrored slice that exists is the gateway mirror's,
# and its endpoints are node addresses, which carry no zone.
#
# TAR is a property of EndpointSlice hints. Cross-cluster traffic either does
# not traverse slices or traverses zone-less ones, so TAR is not in the path and
# no configuration puts it there.
printf '\n  cross-cluster services vs EndpointSlices (TAR needs a slice to annotate):\n'
printf '    %-24s %-9s %s\n' SERVICE SLICES 'SELECTOR'
for svc in $(modes_for "$OBSERVER" | awk '{print $2}'); do
  [ -n "$svc" ] || continue
  printf '    %-24s %-9s %s\n' "$svc" \
    "$(kubectl --context="$CTX" -n "$APP_NS" get endpointslices \
        -l "kubernetes.io/service-name=${svc}" --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
    "$(kubectl --context="$CTX" -n "$APP_NS" get svc "$svc" \
        -o jsonpath='{.spec.selector}' 2>/dev/null || echo '')"
done
printf '\n    Zero slices with a live destination count means the service is resolved\n'
printf '    across the Link, not through EndpointSlices -- so TAR cannot see it.\n'

printf '\n  topology configuration actually in force:\n'
kubectl --context="$CTX" -n "$APP_NS" get svc \
  -o custom-columns='SERVICE:.metadata.name,TOPOLOGY_MODE:.metadata.annotations.service\.kubernetes\.io/topology-mode,TRAFFIC_DIST:.spec.trafficDistribution' \
  2>/dev/null | sed 's/^/    /'

printf '\n  kubernetes version (trafficDistribution needs 1.31+):\n'
kubectl --context="$CTX" version -o json 2>/dev/null \
  | jq -r '"    server " + .serverVersion.gitVersion' 2>/dev/null || true

# --- 2. Three certificates, three expiries, one metric ----------------------
#
# The post uses control_identity_cert_expiration_timestamp_seconds as "the
# certificate headroom" and treats it as one number. It is not. There are three
# certificates in play with three different lifetimes, three different blast
# radii and -- this is the part the post gets wrong -- three different detection
# paths, only one of which is a metric.
banner "2. the three certificates, and which of them a metric can see"

printf '\n  workload leaf certs (the metric FM1b reports):\n'
bash "${REPO_ROOT}/verify/cert-headroom.sh" "$OBSERVER" 2>/dev/null | sed 's/^/  /' | tail -12

printf '\n  issuer and trust anchor (no metric exists; linkerd check is the only path):\n'
# No `head` on the end of this, and `|| true` on the whole thing.
#
# Two ways this pipeline kills the script, both documented elsewhere in this
# repo and both hit while writing it. `head -N` closes the pipe while the CLI is
# still writing, the CLI dies with SIGPIPE, and `pipefail` turns that into a 141
# that `set -e` treats as fatal. And `linkerd check` legitimately exits non-zero
# whenever any check fails -- which is exactly the case worth reporting here.
# Either one silently truncated this script after section 2.
{ linkerd --context="$CTX" check --proxy 2>&1 \
    | grep -iE "certificate|anchor|issuer|expir" | sed 's/^/    /'; } || true

cat <<'EOF'

  If the leaf table above shows ~24h and the issuer/anchor lines show months,
  that is the point: FM1b's headroom number is the LEAF clock. It says how long
  running proxies keep working with linkerd-identity down. It says nothing about
  the issuer or the trust anchor, which fail globally, have no metric at all,
  and are only surfaced by `linkerd check` warning at 60 days.
EOF

# --- 3. The unexplained active-pool baseline --------------------------------
#
# active has baselined at 4, not 3, across two separate runs, with exactly three
# Running pods per cluster. It is not cosmetic: it sets the HAZL band, and the
# band decides whether FM3 produces a result at all.
banner "3. the active-pool baseline, per cluster and per mode"

# Only clusters that actually run a generator. Every one of these helpers reads
# deploy/loadgen's proxy metrics, and since LOAD_CLUSTERS was narrowed to west
# alone -- so that a fault removes serving capacity without also removing demand
# -- the other clusters have no generator to read. Querying them would print
# empty columns that look like a broken mesh rather than an absent instrument.
LOAD_CLUSTERS="${LOAD_CLUSTERS:-west}"
printf '\n  reading from the load-generating clusters only: %s\n' "$LOAD_CLUSTERS"
printf '\n  %-9s %-22s %-8s %-8s %s\n' CLUSTER SERVICE ACTIVE AVAIL 'BAND'
printf -- '  --------------------------------------------------------------------\n'
for c in $LOAD_CLUSTERS; do
  modes_for "$c" | while read -r mode svc; do
    [ -n "$svc" ] || continue
    printf '  %-9s %-22s %-8s %-8s %s\n' "$c" "$svc" \
      "$(active_endpoints "$c" "$svc")" \
      "$(endpoint_pool "$c" "$svc")" \
      "$(hazl_load "$c" "$svc" | awk '{printf "load=%s [%s .. %s]", $1, $2, $3}')"
  done
done

printf '\n  real pod population, for comparison:\n'
for c in $(clusters); do
  printf '    %-9s %s Running\n' "$c" \
    "$(kubectl --context="$(ctx "$c")" -n "$APP_NS" get pods -l app=app \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
done

cat <<'EOF'

  active should equal the number of same-zone endpoints the balancer is using.
  If it reads 4 against 3 Running pods per cluster, that is the open question
  from both previous runs -- and FM3's fault must be sized off the band it
  actually produces, not the one the documented default assumes.
EOF

banner "nothing was injected; the rig is unchanged"
