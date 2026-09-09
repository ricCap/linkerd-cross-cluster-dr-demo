#!/usr/bin/env bash
# Install observability (linkerd-viz) and the chaos tooling (Chaos Mesh).
#
# NOTE ON PROMETHEUS TOPOLOGY
# The original design called for a single Prometheus scraping all three
# clusters over the flat network, to save memory. With Docker at ~19.5GB and the
# whole environment idling at ~4.5GB, that optimisation buys nothing and costs a
# lot of reader-facing complexity (cross-cluster kubernetes_sd credentials).
# So: one linkerd-viz per cluster, the standard supported layout, and
# verify/lib.sh queries all three and merges. If you are running this on a
# smaller machine, that is the first thing to change.
#
# Chaos Mesh needs one k3s-specific setting: the container runtime socket lives
# at /run/k3s/containerd/containerd.sock, not the default Docker path. Without
# it chaos-daemon starts but every fault injection fails at runtime.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl linkerd helm

CHAOS_MESH_VERSION="${CHAOS_MESH_VERSION:-2.7.2}"
K3S_CONTAINERD_SOCKET=/run/k3s/containerd/containerd.sock

# --- linkerd-viz ------------------------------------------------------------

for name in $(clusters); do
  c="$(ctx "$name")"

  if kubectl --context="$c" get ns linkerd-viz >/dev/null 2>&1; then
    log "cluster '${name}': linkerd-viz already installed"
  else
    log "cluster '${name}': installing linkerd-viz"
    linkerd --context="$c" viz install | kubectl --context="$c" apply -f - >/dev/null
  fi
done

log "waiting for linkerd-viz"
for name in $(clusters); do
  kubectl --context="$(ctx "$name")" -n linkerd-viz \
    rollout status deploy --timeout=300s >/dev/null 2>&1 \
    || warn "cluster '${name}': linkerd-viz slow to start"
done

# --- chaos mesh -------------------------------------------------------------

helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
helm repo update chaos-mesh >/dev/null 2>&1 || true

for name in $(clusters); do
  c="$(ctx "$name")"

  if helm --kube-context="$c" status chaos-mesh -n chaos-mesh >/dev/null 2>&1; then
    log "cluster '${name}': chaos-mesh already installed"
    continue
  fi

  log "cluster '${name}': installing chaos-mesh ${CHAOS_MESH_VERSION}"
  helm --kube-context="$c" install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-mesh --create-namespace \
    --version "$CHAOS_MESH_VERSION" \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath="$K3S_CONTAINERD_SOCKET" \
    --set dashboard.create=false \
    --wait --timeout 5m >/dev/null \
    || warn "cluster '${name}': chaos-mesh install reported an error"

  ok "  chaos-mesh installed"
done

# --- verify -----------------------------------------------------------------

echo
failed=0
for name in $(clusters); do
  c="$(ctx "$name")"
  printf '\n--- %s ---\n' "$name"

  viz_ok=no
  linkerd --context="$c" viz check 2>&1 | grep -q 'Status check results are √' && viz_ok=yes

  daemons="$(kubectl --context="$c" -n chaos-mesh get pods -l app.kubernetes.io/component=chaos-daemon \
    --no-headers 2>/dev/null | grep -c Running || true)"
  nodes="$(kubectl --context="$c" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  printf '  linkerd-viz:  %s\n' "$viz_ok"
  printf '  chaos-daemon: %s/%s nodes\n' "$daemons" "$nodes"

  [ "$viz_ok" = "yes" ] || { warn "  linkerd-viz unhealthy"; failed=$((failed + 1)); }
  [ "$daemons" = "$nodes" ] || { warn "  chaos-daemon not on every node"; failed=$((failed + 1)); }
done

echo
[ "$failed" -eq 0 ] || die "${failed} observability/chaos check(s) failed"
ok "observability and chaos tooling ready on all clusters"
