#!/usr/bin/env bash
# Shared topology, configuration and helpers for every script in this repo.
#
# Deliberately bash 3.2 compatible (no associative arrays) so this runs on a
# stock macOS shell as well as Linux CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export REPO_ROOT

# --- topology ---------------------------------------------------------------
#
# name : region : pod CIDR : service CIDR
#
# east and central deliberately share region-a, so the "region failure"
# experiment (FM4) is an honest simultaneous loss of two clusters rather than a
# relabelled single-cluster failure.
#
# WHICH clusters share the region is deliberate too, and it is a DR lesson
# rather than an implementation detail.
#
# The observability stack -- Grafana and the federating Prometheus -- has to
# live somewhere, and 09-grafana.sh puts it in west. The first version of this
# table put west and central in region-a, which meant the region experiment
# destroyed the cluster hosting the recorder: the failover worked perfectly and
# none of it was visible while it happened. That is the same mistake as putting
# your status page in the datacentre it reports on.
#
# So west is now the cluster no experiment touches:
#
#   control plane (FM1)  targets central
#   cluster loss  (FM2)  targets east
#   zone brownout (FM3)  browns out app pods only, in every cluster
#   region loss   (FM4)  targets region-a = east + central
#
# Be honest about what that does and does not fix. It makes the exercise
# observable, and verify/fm4-verify.sh now refuses to run if the stack is inside
# the target region. It does NOT make an in-cluster observability stack safe: we
# only ever fail region-a, and a real regional event does not consult your
# dashboard's placement. The production answer is still to host it outside every
# cluster it observes.
#
# Pod and service CIDRs must not overlap across clusters: on a flat network a
# pod IP has to be globally unambiguous or cross-cluster routing is impossible.
CLUSTER_TABLE="
west:region-b:10.21.0.0/16:10.245.0.0/16
east:region-a:10.22.0.0/16:10.246.0.0/16
central:region-a:10.23.0.0/16:10.247.0.0/16
"

# --- zones ------------------------------------------------------------------
#
# ZONES ARE REGION-SCOPED, AND THAT IS NOT A COSMETIC DETAIL.
#
# `us-east-1a` and `us-west-2a` are unrelated failure domains that happen to
# share a letter. Every cluster here used to label its nodes zone-a/zone-b/
# zone-c, so west's `zone-c` and east's `zone-c` were the SAME STRING to the
# proxy -- describing a zone that spans two regions, which does not exist.
#
# It mattered well beyond naming. `dst_zone_locality` is computed by comparing
# those labels, so cross-REGION traffic was being reported as zone-local, and
# FM3's resting measurement -- "HAZL used 3 of 9 endpoints, the same-zone pod in
# each of the three clusters, all local" -- rested on the duplication. With
# region-scoped names a west client has no zone-local endpoint in region-a at
# all, and that finding needs re-measuring. See results/SHORTCOMINGS.md §16.
#
# Names are `zone-<region letter><n>`: zone-a1..a3 in region-a, zone-b1..b3 in
# region-b. Two clusters in ONE region genuinely can sit in the same zones, so
# east and central still share theirs -- that part was always right.
ZONES_PER_REGION="${ZONES_PER_REGION:-3}"

# The zones of a region, one per line.  region-a -> zone-a1 zone-a2 zone-a3
zones_in_region() {
  local letter="${1##*-}" n=1
  while [ "$n" -le "$ZONES_PER_REGION" ]; do
    printf 'zone-%s%s\n' "$letter" "$n"
    n=$(( n + 1 ))
  done
}

# The zones a given cluster's nodes live in.
zones_for() { zones_in_region "$(cluster_region "$1")"; }

# Every distinct zone in the mesh, across all regions.
all_zones() {
  local r
  for r in $(regions); do zones_in_region "$r"; done
}

zone_count() { echo "$ZONES_PER_REGION"; }

# Replicas per workload. One pod per zone, so each zone holds exactly one
# endpoint -- which is what makes the endpoint arithmetic in the experiments
# legible (9 endpoints = 3 zones x 3 clusters).
APP_REPLICAS="${APP_REPLICAS:-$(zone_count)}"

# --- workloads --------------------------------------------------------------
#
# name : mode : replicas : label key : label value : scope
#
# One podinfo workload per exposure mode, so a single fault produces three
# directly comparable outcomes. `scope` is `all` or a single cluster name.
#
# app-gateway lives in east ALONE, and that is the whole reason the gateway lane
# always points there: it is the only gateway export in the rig. Anything
# drawing or deploying the app has to know that, which is why it is here rather
# than written out in 06-apps.sh -- the same reason modes_for exists. When the
# deployer and the measurer disagreed about which services exist where, nothing
# errored: the generator drove one service while the runner measured another and
# reported the untouched mode as zero traffic.
WORKLOAD_TABLE="
app:federated:${APP_REPLICAS}:mirror.linkerd.io/federated:member:all
app-flat:flat:${APP_REPLICAS}:mirror.linkerd.io/exported:remote-discovery:all
app-gateway:gateway:${APP_REPLICAS}:mirror.linkerd.io/exported:true:east
"

# All workload names, in declaration order.
workloads() {
  echo "$WORKLOAD_TABLE" | grep -v '^[[:space:]]*$' | cut -d: -f1
}

# workload_field <name> <1=name|2=mode|3=replicas|4=label_key|5=label_value|6=scope>
workload_field() {
  local name="$1" field="$2" row
  row="$(echo "$WORKLOAD_TABLE" | grep "^${name}:" || true)"
  if [ -z "$row" ]; then
    echo "lib.sh: unknown workload '${name}'" >&2
    return 1
  fi
  echo "$row" | cut -d: -f"$field"
}

# The workloads deployed in a given cluster, as
# "<name> <mode> <replicas> <label_key> <label_value>" lines.
workloads_in() {
  local want="$1" w scope
  for w in $(workloads); do
    scope="$(workload_field "$w" 6)"
    if [ "$scope" = "all" ] || [ "$scope" = "$want" ]; then
      printf '%s %s %s %s %s\n' \
        "$w" "$(workload_field "$w" 2)" "$(workload_field "$w" 3)" \
        "$(workload_field "$w" 4)" "$(workload_field "$w" 5)"
    fi
  done
}

# Clusters that host a multicluster gateway: wherever the gateway-mode workload
# lives, since that export is what a gateway link exists to reach.
gateway_hosts() {
  local w scope
  for w in $(workloads); do
    [ "$(workload_field "$w" 2)" = "gateway" ] || continue
    scope="$(workload_field "$w" 6)"
    if [ "$scope" = "all" ]; then clusters; else echo "$scope"; fi
  done
}

# How many endpoints a federated service should have across the whole mesh.
#
# 9 was hardcoded in two runners while CLUSTER_TABLE and WORKLOAD_TABLE were
# meant to be the single source of truth for topology. Change the replica count
# or add a cluster and the runners die on a baseline assertion that has nothing
# to do with what is being tested -- so derive it.
federated_pool_size() {
  local w n=0 replicas scope
  for w in $(workloads); do
    [ "$(workload_field "$w" 2)" = "federated" ] || continue
    replicas="$(workload_field "$w" 3)"
    scope="$(workload_field "$w" 6)"
    if [ "$scope" = "all" ]; then
      n=$(( n + replicas * $(clusters | wc -w) ))
    else
      n=$(( n + replicas ))
    fi
  done
  echo "$n"
}

DOCKER_NET="${DOCKER_NET:-dr-net}"
DOCKER_NET_SUBNET="${DOCKER_NET_SUBNET:-172.28.0.0/16}"

K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.6-k3s1}"

# oss | bel   -- see clusters/04-linkerd.sh
LINKERD_FLAVOR="${LINKERD_FLAVOR:-oss}"

# Enforce mesh membership, rather than merely requesting it.
#
# Linkerd ships two permissive defaults that together make it possible to run
# workloads OUTSIDE the mesh without anything complaining:
#
#   proxy-injector failurePolicy: Ignore
#       Injection is a mutating webhook. If the injector is unavailable when a
#       pod is admitted -- which is exactly what happens while a cluster is
#       restarting -- the pod is admitted WITHOUT a proxy and nothing retries.
#
#   defaultInboundPolicy: all-unauthenticated
#       Meshed pods accept connections from anyone, including unmeshed plaintext
#       clients. So the unmeshed pod's traffic is silently accepted.
#
# Both defaults are reasonable for incremental adoption and dangerous for DR: a
# control plane blip leaves you with Running, Ready pods serving plaintext, with
# authorization policy unenforced, and no signal anywhere.
#
# ENFORCE_MESH=1 sets failurePolicy=Fail and defaultInboundPolicy=all-authenticated.
#
# Understand the trade-off before enabling it in anger: with failurePolicy=Fail,
# pods CANNOT be created while the injector is down. That converts a silent
# security failure into a loud availability failure. That is usually the right
# trade, but it is a choice, and it should be made deliberately rather than
# inherited.
ENFORCE_MESH="${ENFORCE_MESH:-0}"

# LINKERD_HA=1 installs the control plane in high-availability mode: three
# replicas of each controller, pod anti-affinity, and resource requests.
#
# This matters more than it looks. Every result in results/ was taken on a
# SINGLE-replica control plane, where `kubectl scale linkerd-destination
# --replicas=0` is a total control plane outage. On an HA install that same
# event is what HA exists to absorb -- you lose one replica of three. So FM1 as
# originally run measures the failure mode of a configuration the write-up
# itself tells readers not to use, and then draws DR conclusions from it.
#
# Not the default, because three control planes plus Chaos Mesh across three
# k3d clusters is a real memory increase over the ~20GB the README already asks
# for, and silently exceeding it produces evictions that look like experiment
# results. Opt in, and watch the first build.
LINKERD_HA="${LINKERD_HA:-0}"

# PROFILE is the single switch the experiments should actually be run under.
#
#   PROFILE=default     Linkerd's out-of-the-box settings. The arm that produces
#                       the silent-unmeshed-pod finding, because that finding is
#                       caused BY the defaults (failurePolicy=Ignore plus
#                       all-unauthenticated).
#   PROFILE=production  What the write-up recommends: HA control plane, mesh
#                       membership enforced. Claims about "what a mesh does in a
#                       disaster" belong to this arm; the other one is the
#                       contrast.
#
# Neither is a superset of the other, which is why both are worth running: under
# `production`, a control plane outage stops pods being CREATED instead of
# silently admitting them unmeshed. Different symptom, different runbook entry.
PROFILE="${PROFILE:-default}"
case "$PROFILE" in
  production) LINKERD_HA=1; ENFORCE_MESH=1 ;;
  default)    ;;
  *) echo "lib.sh: PROFILE must be 'default' or 'production', got '${PROFILE}'" >&2; exit 1 ;;
esac

APP_NS="${APP_NS:-dr-demo}"

# --- topology accessors -----------------------------------------------------

# All cluster names, in declaration order.
clusters() {
  echo "$CLUSTER_TABLE" | grep -v '^[[:space:]]*$' | cut -d: -f1
}

# cluster_field <cluster> <1=name|2=region|3=pod_cidr|4=svc_cidr>
cluster_field() {
  local name="$1" field="$2" row
  row="$(echo "$CLUSTER_TABLE" | grep "^${name}:" || true)"
  if [ -z "$row" ]; then
    echo "lib.sh: unknown cluster '${name}'" >&2
    return 1
  fi
  echo "$row" | cut -d: -f"$field"
}

cluster_region()   { cluster_field "$1" 2; }
cluster_pod_cidr() { cluster_field "$1" 3; }
cluster_svc_cidr() { cluster_field "$1" 4; }

# Every pod AND service CIDR across all clusters, comma-joined.
#
# This is what Linkerd's `clusterNetworks` must be set to. It is easy to get
# wrong: pod CIDRs alone are not enough, because the proxy also has to treat
# traffic to *service* IPs in remote clusters as in-mesh. `linkerd check` catches
# it with "cluster networks contains all services", but only after install.
all_cluster_networks() {
  local c out=""
  for c in $(clusters); do
    out="${out}$(cluster_pod_cidr "$c"),$(cluster_svc_cidr "$c"),"
  done
  echo "${out%,}"
}

# Clusters belonging to a region -- used by the FM4 region-loss experiment.
# Every distinct region in the topology table, in declaration order.
regions() {
  echo "$CLUSTER_TABLE" | grep -v '^[[:space:]]*$' | cut -d: -f2 | awk '!seen[$0]++'
}

clusters_in_region() {
  local want="$1" c
  for c in $(clusters); do
    if [ "$(cluster_region "$c")" = "$want" ]; then echo "$c"; fi
  done
}

# k3d prefixes every context and container name with "k3d-".
ctx() { echo "k3d-$1"; }

# Node container names for a cluster, as Docker sees them.
node_containers() {
  local name="$1"
  docker ps --format '{{.Names}}' \
    | grep -E "^k3d-${name}-(server|agent)-[0-9]+$" \
    | sort
}

# --- output helpers ---------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

# --- preflight --------------------------------------------------------------

need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not on PATH: $t"
  done
}

# Pick the CLI that matches the flavor. The two are installed side by side --
# OSS in ~/.linkerd2, enterprise in ~/.linkerd2-bel (INSTALLROOT) -- because the
# enterprise CLI is needed for the enterprise multicluster and viz extensions,
# and clobbering one with the other makes LINKERD_FLAVOR meaningless.
if [ "$LINKERD_FLAVOR" = "bel" ] && [ -x "$HOME/.linkerd2-bel/bin/linkerd" ]; then
  export PATH="$HOME/.linkerd2-bel/bin:$PATH"
elif [ -x "$HOME/.linkerd2/bin/linkerd" ]; then
  export PATH="$PATH:$HOME/.linkerd2/bin"
fi

# Load local settings (license, etc). Gitignored.
if [ -f "${REPO_ROOT}/settings.local.sh" ]; then
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/settings.local.sh"
fi

# Licenses copied out of a browser are frequently hard-wrapped. A BUOYANT_LICENSE
# with newlines in it is a valid-looking JWT whose ES256 signature will not
# verify, and the resulting error ("token signature is invalid") points at the
# key being wrong rather than at the whitespace. Strip it defensively.
if [ -n "${BUOYANT_LICENSE:-}" ]; then
  BUOYANT_LICENSE="$(printf '%s' "$BUOYANT_LICENSE" | tr -d '[:space:]')"
  export BUOYANT_LICENSE
fi

# Two `linkerd check` failures are unavoidable in this environment and do NOT
# indicate a problem:
#
#   "remote cluster access credentials are valid"
#   "clusters share trust anchors"
#
# Both are evaluated by the CLI running on the HOST, using the kubeconfig
# embedded in each link's credentials secret. That kubeconfig points at a
# Docker-network address (172.28.x.x) which only containers can reach, so the
# host times out. The in-pod service-mirror controllers reach it fine.
#
# We do NOT blanket-ignore check failures. 04-linkerd.sh independently compares
# trust anchors across clusters using each cluster's own kubeconfig -- a
# stronger test than the one being skipped -- and verify/multicluster.sh proves
# the mirrors actually work.
KNOWN_HOST_CHECK_FAILURES='remote cluster access credentials are valid|clusters share trust anchors'

# Print any check failures OTHER than the known host-reachability ones.
# Empty output means healthy.
linkerd_check_unexpected() {
  local ctx="$1" wait="${2:-45s}"
  linkerd --context="$ctx" check --wait="$wait" 2>&1 \
    | grep '×' \
    | grep -vE "${KNOWN_HOST_CHECK_FAILURES}|Status check results" \
    || true
}

# --- partitioning without losing addresses ----------------------------------
#
# `docker network disconnect` + `connect` reassigns addresses in reattach order,
# so nodes come back on different IPs than they left with. k3s then wedges (its
# serving certificate and internal config reference the old address) and every
# Linkerd Link, which pins the target API address at creation, is orphaned.
#
# That is a Docker artifact, not cloud behaviour: on EKS/GKE a node keeps its
# address across a network event. Letting it happen here would inject a failure
# mode real users do not have, and it made two experiments unrecoverable.
#
# So we record each container's address before cutting it off and reattach with
# exactly that address. The partition then models what it is supposed to model
# -- packets stop flowing -- and nothing else.

ip_state_file() { echo "${REPO_ROOT}/clusters/.generated/node-ips.txt"; }

# Record <container> <ip> for every node in the given clusters.
save_node_ips() {
  local f n ip
  f="$(ip_state_file)"; mkdir -p "$(dirname "$f")"
  for c in "$@"; do
    for n in $(docker ps -a --format '{{.Names}}' | grep -E "^k3d-${c}-(server|agent)-[0-9]+$"); do
      ip="$(docker inspect "$n" -f "{{(index .NetworkSettings.Networks \"${DOCKER_NET}\").IPAddress}}" 2>/dev/null)"
      [ -n "$ip" ] || continue
      grep -v "^${n} " "$f" > "${f}.tmp" 2>/dev/null || true
      mv -f "${f}.tmp" "$f" 2>/dev/null || true
      echo "${n} ${ip}" >> "$f"
    done
  done
}

# Reattach a container to the network on the address it previously held.
# Falls back to a normal connect if we have no record of it.
restore_node_ip() {
  local n="$1" f ip
  f="$(ip_state_file)"
  ip="$(awk -v n="$n" '$1 == n {print $2; exit}' "$f" 2>/dev/null || true)"
  if [ -n "$ip" ]; then
    docker network connect --ip "$ip" "$DOCKER_NET" "$n" 2>/dev/null && return 0
  fi
  docker network connect "$DOCKER_NET" "$n" 2>/dev/null || true
}

# Which cluster does an endpoint address belong to?
#
# Two kinds of address show up in proxy metrics and only one of them is a pod:
#
#   pod IP        10.2x.0.0/16, one range per cluster. Federated members and
#                 flat mirrors resolve to these.
#   node address  the target cluster's linkerd-gateway Service is type
#                 LoadBalancer, and klipper-lb publishes NODE addresses on the
#                 shared Docker network (172.28.0.0/16). A gateway mirror
#                 resolves to that, never to a backing pod.
#
# Matching pod CIDRs alone therefore files every gateway-mode request under
# "other" -- which reads as "traffic went somewhere unknown" rather than
# "traffic went to east's gateway", and quietly breaks any per-cluster
# distribution or convergence figure taken against a gateway mirror. Nothing
# errors; the numbers are just wrong, which is the failure mode this repo keeps
# running into.
#
# The node table is written by save_node_ips at setup time. If it is missing
# (someone ran a verifier against a rig built before this existed) gateway
# addresses fall back to "other", which is the old behaviour rather than a crash.
cluster_of_ip() {
  local ip="$1" c prefix node
  for c in $(clusters); do
    prefix="$(cluster_pod_cidr "$c" | cut -d. -f1,2)."
    case "$ip" in "$prefix"*) echo "$c"; return;; esac
  done

  node="$(awk -v ip="$ip" '$2 == ip { print $1; exit }' "$(ip_state_file)" 2>/dev/null || true)"
  if [ -n "$node" ]; then
    # k3d-east-server-0 -> east. Same affix pattern node_containers matches on.
    echo "$node" | sed -E 's/^k3d-//; s/-(server|agent)-[0-9]+$//'
    return
  fi

  echo "other"
}

# --- exposure-mode targets --------------------------------------------------
#
# A mirrored service only exists in the clusters that link to its source, so the
# per-mode target list is NOT uniform. east cannot resolve `app-flat-east` -- that is
# its own service, and nothing mirrors a cluster to itself -- and only the
# clusters carrying a gateway link resolve a `-gw` mirror at all.
#
# This lives in one place because the load generator and every experiment runner
# need the same answer. When they disagreed, the generator drove one service
# while the runner measured another. That does not error: it reports zero
# traffic for a mode that was simply never exercised.

flat_target_for() {
  case "$1" in
    east) echo "app-flat-west" ;;   # east links to west and central
    *)    echo "app-flat-east" ;;   # west and central both link to east
  esac
}

# Must stay in step with GATEWAY_LINKS in clusters/05-multicluster.sh.
gateway_target_for() {
  case "$1" in
    west|central) echo "app-gateway-east-gw" ;;
    *)            echo "" ;;
  esac
}

# The exposure modes resolvable from a cluster, as "<mode> <service>" lines.
# Emits the gateway row only where a gateway link exists.
modes_for() {
  local gw
  echo "federated app-federated"
  echo "flat $(flat_target_for "$1")"
  gw="$(gateway_target_for "$1")"
  # `if`, not `&&`: under `set -e` a false compound as the last command of a
  # function makes the function itself fail.
  if [ -n "$gw" ]; then echo "gateway $gw"; fi
}

# Wait until a command succeeds, or give up.
#   retry <attempts> <sleep_seconds> <command...>
retry() {
  local attempts="$1" delay="$2"; shift 2
  local i=1
  while [ "$i" -le "$attempts" ]; do
    if "$@"; then return 0; fi
    sleep "$delay"
    i=$((i + 1))
  done
  return 1
}
