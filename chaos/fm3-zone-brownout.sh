#!/usr/bin/env bash
# FM3 -- zone brownout (the HAZL experiment).
#
#   chaos/fm3-zone-brownout.sh start [zone] [latency]
#   chaos/fm3-zone-brownout.sh stop
#
# A brownout, not a blackout. The pods stay Ready, the endpoints stay in the
# EndpointSlice, and Kubernetes reports nothing wrong. They just get slow.
#
# That is the case ordinary zone-aware routing handles badly: Topology Aware
# Routing keys off topology, not health, so it keeps sending traffic to a zone
# that is technically up and functionally useless. HAZL keys off observed load
# -- latency x throughput -- so a latency increase alone is enough to make it
# widen the endpoint pool.
#
# WHY THE LATENCY NUMBER IS WHAT IT IS
#
# HAZL expands when the load average crosses the band's high threshold. The
# band is NOT the documented 0.8 / 2.0: those are per-endpoint values, and the
# exposed band is the aggregate for the active pool. With 3 active endpoints
# the real threshold is 6.0 (measured: exactly 2.00 x active).
#
# load = latency x throughput, so at 30 rps we need latency > 6.0 / 30 = 200ms
# to cross it. The default below is comfortably past that.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl

ACTION="${1:-start}"
CHAOS_NS=chaos-mesh
NAME=fm3-zone-brownout

# Which workloads the brownout slows.
#
# It used to be `app` alone, which quietly undermined the whole design: the
# repo exposes one workload three ways so that a SINGLE fault produces three
# comparable outcomes, and a fault that only touches the federated members is
# not that fault. app-flat and app-gateway sat untouched, so any three-mode comparison
# drawn from this experiment would have been comparing a degraded service
# against two healthy ones.
#
# app  federated      app-flat  flat mirror      app-gateway  gateway mirror
BROWNOUT_APPS="${BROWNOUT_APPS:-app app-flat app-gateway}"

# Which clusters get browned out. Everything except the load generator's own
# cluster, because west must stay unaffected: it is the observer, and slowing
# the zone the client lives in measures the client as much as the mesh.
#
# This narrows the fault -- a zone is a cross-cluster slice, and this now slows
# that slice in two clusters of three rather than all three. The claim under
# test is unchanged (a slow-but-healthy zone is invisible to Kubernetes and
# HAZL steps off it anyway), and the arithmetic moves: west's own zone-local
# endpoint stays fast, so the pool has one good local option it did not have
# before. Read the band before injecting, as always.
BROWNOUT_CLUSTERS="${BROWNOUT_CLUSTERS:-$(for c in $(clusters); do
  [ "$c" = "${LOAD_CLUSTER:-west}" ] || echo "$c"
done)}"

# Which zone to brown out.
#
# It used to be the load generator's own zone, on the reasoning that this is the
# zone HAZL keeps traffic inside, so browning out any other would change
# nothing. Zones are region-scoped now, and that reasoning broke with them: the
# generator lives in west (region-b, zone-b*) while the brownout targets
# region-a (zone-a*), so the detected zone does not exist on any node being
# targeted. The selector would match nothing and the experiment would report a
# clean run having injected no fault at all.
#
# Default to the first zone of the region the target clusters are in, and then
# PROVE the zone exists there before applying anything. A chaos experiment that
# silently selects zero pods is worse than one that fails.
detect_zone() {
  local first_target
  first_target="$(echo $BROWNOUT_CLUSTERS | awk '{print $1}')"
  [ -n "$first_target" ] || { echo ""; return; }
  zones_for "$first_target" | head -1
}

ZONE="${2:-$(detect_zone)}"
LATENCY="${3:-400ms}"

case "$ACTION" in
  start)
    [ -n "$ZONE" ] || die "no zone to brown out (BROWNOUT_CLUSTERS is empty?)"

    # Refuse to inject a fault that cannot match anything. Chaos Mesh reports no
    # error for a selector that matches zero pods, so without this the run looks
    # successful and measures nothing -- the exact failure mode this repo keeps
    # finding in its own instruments.
    for name in $BROWNOUT_CLUSTERS; do
      if ! kubectl --context="$(ctx "$name")" get nodes \
           -l "topology.kubernetes.io/zone=${ZONE}" \
           -o name 2>/dev/null | grep -q .; then
        die "cluster '${name}' has no node in zone '${ZONE}'.
Zones are region-scoped: $(cluster_region "$name") uses $(zones_for "$name" | tr '\n' ' ')."
      fi
    done

    log "FM3: browning out '${ZONE}' (+${LATENCY} latency) in: $(echo $BROWNOUT_CLUSTERS | tr '\n' ' ')"
    log "  apps: ${BROWNOUT_APPS}"
    log "  pods stay Ready throughout -- this is a brownout, not a failure"

    for name in $BROWNOUT_CLUSTERS; do
      for app in $BROWNOUT_APPS; do
        # One NetworkChaos per app rather than one with an expressionSelector.
        # Chaos Mesh's labelSelectors are an exact-match map, so "app in (a,b,c)"
        # needs the expression form -- which is a schema this rig has never
        # exercised. Three objects with the selector that is known to work is
        # the boring choice, and a brownout experiment is a bad place to be
        # debugging the injector.
        kubectl --context="$(ctx "$name")" apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: ${NAME}-${app}
  namespace: ${CHAOS_NS}
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - ${APP_NS}
    labelSelectors:
      app: ${app}
    nodeSelectors:
      topology.kubernetes.io/zone: ${ZONE}
  delay:
    latency: "${LATENCY}"
    jitter: "20ms"
    correlation: "50"
  direction: to
EOF
      done
      ok "  ${name}: brownout applied to ${ZONE}"
    done

    cat <<EOF

Injected. What to watch:

  outbound_http_balancer_adaptive_load_average   should climb past the band high
  outbound_http_balancer_endpoints{ready}        should STEP UP as HAZL widens
  dst_zone_locality                              should start showing "remote"

  verify/fm3-verify.sh runs this end to end and asserts on all three -- for the
  federated service, and then compares what the flat and gateway mirrors did
  about the same fault.
EOF
    ;;

  stop)
    log "FM3: removing the brownout"
    # Every cluster, not BROWNOUT_CLUSTERS: if the scope changed between runs a
    # stray NetworkChaos would keep a zone slow and read as a HAZL result.
    for name in $(clusters); do
      # "$NAME" with no suffix is the pre-three-mode object. Deleting it too
      # means a rig built before this change does not keep a stray brownout
      # applied to app forever -- which would look like a HAZL result.
      for obj in "$NAME" $(for a in $BROWNOUT_APPS; do echo "${NAME}-${a}"; done); do
        # --timeout, and a finalizer fallback.
        #
        # Chaos Mesh puts a finalizer on every NetworkChaos and removes it only
        # after its controller has recovered the affected pods. If that
        # controller is unhealthy -- or the pods it wants are already gone --
        # the delete blocks FOREVER. `kubectl delete` waits by default, this
        # runs from an EXIT trap, and the trap has no deadline: one run hung for
        # thirty minutes with the brownout still applied, so the rig looked
        # healthy to nothing and every later run inherited a slowed zone.
        #
        # A cleanup that cannot fail is worse than one that reports failure.
        if ! kubectl --context="$(ctx "$name")" -n "$CHAOS_NS" \
             delete networkchaos "$obj" --ignore-not-found --timeout=30s >/dev/null 2>&1; then
          # Still there: drop the finalizer and delete again. Leaving a brownout
          # applied is the worse outcome by far.
          kubectl --context="$(ctx "$name")" -n "$CHAOS_NS" \
            patch networkchaos "$obj" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
          kubectl --context="$(ctx "$name")" -n "$CHAOS_NS" \
            delete networkchaos "$obj" --ignore-not-found --timeout=15s >/dev/null 2>&1 || true
          warn "  ${name}: ${obj} needed its finalizer removed to delete"
        fi
      done
      # Say what is actually true, rather than announcing success unconditionally.
      left="$(kubectl --context="$(ctx "$name")" -n "$CHAOS_NS" \
        get networkchaos -o name 2>/dev/null | grep -c "$NAME" || true)"
      if [ "${left:-0}" -eq 0 ]; then
        ok "  ${name}: cleared"
      else
        warn "  ${name}: ${left} chaos object(s) STILL APPLIED -- the zone is still slow"
      fi
    done
    ;;

  *)
    die "usage: fm3-zone-brownout.sh <start|stop> [zone] [latency]"
    ;;
esac
