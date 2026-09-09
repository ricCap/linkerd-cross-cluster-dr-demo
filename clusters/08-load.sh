#!/usr/bin/env bash
# Deploy the k6 load generator.
#
#   08-load.sh start [steady|ramp]   deploy and run
#   08-load.sh stop                  remove
#   08-load.sh logs                  follow output
#
# WHERE THE LOAD COMES FROM, AND WHY IT MOVED
#
# It used to run in every cluster, reasoning that killing the only generator
# would stop an experiment rather than measure it. That reasoning was sound and
# the consequence was not: co-locating generators with the workloads they drive
# means a fault removes DEMAND at the same moment it removes SUPPLY.
#
# Measured during FM4, from the archived TSDB -- outbound rate per generating
# cluster, then inbound rate at the survivor:
#
#   outbound  west     30  31  30  29  30  30  30  30   unchanged
#             east     29  30  19  30                   series ends: generator died
#             central  29  30  30                       series ends: generator died
#
#   inbound   west     68  61  31  26   8  10  38  52   it went DOWN
#
# So "the surviving region absorbed the traffic" was never tested: west served
# LESS during the outage, because two thirds of the offered load died with the
# clusters that were generating it. The check measured west's own client-side
# rate holding at 30 rps, which is a much narrower claim than its name.
#
# Load now comes from LOAD_CLUSTERS (default: west alone), which no experiment
# touches. Offered load stays constant while serving capacity shrinks, so
# absorption is a measurement rather than an assumption.
#
# The cost, stated plainly: FM1 measures from the cluster whose control plane it
# breaks -- a stale endpoint pool is a property of one proxy, and west's view is
# maintained by west's own destination controller, so a west client cannot see
# central's freeze. verify/fm1-verify.sh therefore brings up its own generator
# in the target cluster for the run and removes it afterwards.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl

K6_IMAGE="${K6_IMAGE:-grafana/k6:1.3.0}"

# Which clusters generate load. Default west: it is the observer, and it is the
# one cluster no experiment is allowed to touch. Override to reproduce the old
# every-cluster behaviour, or to drive a single named cluster.
LOAD_CLUSTERS="${LOAD_CLUSTERS:-west}"
ACTION="${1:-start}"
SCRIPT="${2:-steady}"

case "$ACTION" in
  stop)
    # Every cluster, not LOAD_CLUSTERS: a leftover generator from an earlier
    # profile is exactly the kind of thing that quietly re-creates the problem
    # this default exists to remove.
    for name in $(clusters); do
      log "cluster '${name}': removing load generator"
      kubectl --context="$(ctx "$name")" -n "$APP_NS" delete deploy loadgen --ignore-not-found >/dev/null
      kubectl --context="$(ctx "$name")" -n "$APP_NS" delete cm loadgen-scripts --ignore-not-found >/dev/null
    done
    ok "load generators stopped"
    exit 0
    ;;
  logs)
    kubectl --context="$(ctx west)" -n "$APP_NS" logs -f deploy/loadgen -c k6
    exit 0
    ;;
  start) ;;
  *) die "usage: 08-load.sh [start <steady|ramp>|stop|logs]" ;;
esac

[ -f "${REPO_ROOT}/load/${SCRIPT}.js" ] || die "no such load script: load/${SCRIPT}.js"

RPS="${RPS:-30}"
DURATION="${DURATION:-30m}"

# Which mirrored services actually exist in a given cluster is NOT uniform, and
# the answer lives in clusters/lib.sh (flat_target_for / gateway_target_for /
# modes_for) so that the generator and the experiment runners cannot drift apart.
#
# They did drift once, and it does not error: the generator drives one service
# while the runner measures another, and the runner reports zero traffic for a
# mode that was simply never exercised.

for name in $LOAD_CLUSTERS; do
  c="$(ctx "$name")"
  flat_svc="$(flat_target_for "$name")"
  gateway_svc="$(gateway_target_for "$name")"
  log "cluster '${name}': starting load generator (${SCRIPT}, RPS=${RPS})"
  log "  targets: app-federated, ${flat_svc}${gateway_svc:+, ${gateway_svc}}"

  kubectl --context="$c" -n "$APP_NS" create configmap loadgen-scripts \
    --from-file="${REPO_ROOT}/load/" \
    --dry-run=client -o yaml | kubectl --context="$c" apply -f - >/dev/null

  kubectl --context="$c" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
  namespace: ${APP_NS}
  labels:
    app: loadgen
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loadgen
  template:
    metadata:
      labels:
        app: loadgen
      annotations:
        # Restarting the deployment must pick up a changed script.
        dr-demo/script: "${SCRIPT}"
    spec:
      containers:
        - name: k6
          image: ${K6_IMAGE}
          # --address exposes k6's built-in REST API on :6565, whose /v1/metrics
          # endpoint reports every metric k6 is tracking, live. Without it the
          # generator's own view of the run is unreachable: the scripts define
          # dr_requests and dr_errors and NOTHING could read them, so the
          # headline claim -- that requests hang and never complete -- had to be
          # inferred from proxy counters that stay silent, which is exactly what
          # "the request was never sent" also looks like. This makes the client
          # side observable: attempted requests, timeouts, and dropped
          # iterations. Bound to localhost only; verify/lib.sh reads it through
          # kubectl exec, so it needs no Service and is not reachable off-pod.
          args: ["run", "--quiet", "--no-usage-report", "--address", "127.0.0.1:6565", "/scripts/${SCRIPT}.js"]
          env:
            - name: APP_NS
              value: "${APP_NS}"
            - name: RPS
              value: "${RPS}"
            - name: DURATION
              value: "${DURATION}"
            - name: SOURCE_CLUSTER
              value: "${name}"
            - name: FLAT_SVC
              value: "${flat_svc}"
            - name: GATEWAY_SVC
              value: "${gateway_svc}"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { memory: 512Mi }
      volumes:
        - name: scripts
          configMap:
            name: loadgen-scripts
EOF
  ok "  started"
done

log "waiting for generators"
for name in $LOAD_CLUSTERS; do
  kubectl --context="$(ctx "$name")" -n "$APP_NS" \
    rollout status deploy/loadgen --timeout=120s >/dev/null 2>&1 \
    || warn "cluster '${name}': load generator slow to start"
done

ok "load running -- follow with: clusters/08-load.sh logs"
