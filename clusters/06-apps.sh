#!/usr/bin/env bash
# Deploy the demo workload in three different cross-cluster exposure modes.
#
# This is the heart of the experiment design. One application, exposed three
# ways, so that a SINGLE injected fault produces three visibly different
# outcomes side by side:
#
#   app          federated      label mirror.linkerd.io/federated=member
#              Members in all three clusters are unioned into
#              `app-federated`. Losing a cluster should rebalance across
#              the survivors with no client change and no errors.
#
#   api        flat mirror    label mirror.linkerd.io/exported=remote-discovery
#              Mirrored pod-to-pod as `app-flat-east` / `app-flat-central` etc. Note the
#              label value: "remote-discovery", NOT "true". `exported=true`
#              selects GATEWAY mirroring; flat pod-to-pod mirroring is a
#              separate mode with its own selector. Getting this wrong yields
#              no mirror at all, silently. Losing the target cluster should
#              produce hard failures -- the client is pinned to one cluster.
#
#   app-gateway  gateway mirror label mirror.linkerd.io/exported=true
#              Mirrored through east's gateway as `app-gateway-east-gw`. Losing
#              the gateway should fail differently again.
#
# Every service is spread across all three zones so that FM3 (zone brownout)
# has somewhere to shift traffic to.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl

PODINFO_IMAGE="${PODINFO_IMAGE:-ghcr.io/stefanprodan/podinfo:6.9.2}"

# Deploy one podinfo-backed service.
#   deploy_svc <cluster> <name> <replicas> <svc-label-key> <svc-label-value>
# Pass "-" for the label key to expose nothing cross-cluster.
deploy_svc() {
  local cluster="$1" name="$2" replicas="$3" label_key="$4" label_value="$5"
  local c; c="$(ctx "$cluster")"

  kubectl --context="$c" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${APP_NS}
  labels:
    app: ${name}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      # Spread across zones so HAZL and zone-level chaos have something to work
      # with. ScheduleAnyway rather than DoNotSchedule: with 3 nodes and 3
      # replicas a strict constraint deadlocks if any node is cordoned, which
      # FM3's hard-zone variant does deliberately.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: ${name}
      containers:
        - name: podinfo
          image: ${PODINFO_IMAGE}
          ports:
            - name: http
              containerPort: 9898
          env:
            # Lets a human eyeball which cluster answered. Traffic *attribution*
            # in the experiments comes from Linkerd proxy metrics, not this.
            - name: PODINFO_UI_MESSAGE
              value: "${name} in ${cluster}"
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { memory: 128Mi }
          livenessProbe:
            httpGet: { path: /healthz, port: 9898 }
            initialDelaySeconds: 3
          readinessProbe:
            httpGet: { path: /readyz, port: 9898 }
            initialDelaySeconds: 3
EOF

  # Service, optionally carrying the export/federation label.
  local labels=""
  if [ "$label_key" != "-" ]; then
    labels="
    ${label_key}: \"${label_value}\""
  fi

  kubectl --context="$c" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${APP_NS}
  labels:
    app: ${name}${labels}
spec:
  selector:
    app: ${name}
  ports:
    - name: http
      port: 9898
      targetPort: 9898
EOF
}

# --- namespaces -------------------------------------------------------------

for name in $(clusters); do
  c="$(ctx "$name")"
  log "cluster '${name}': creating meshed namespace '${APP_NS}'"
  kubectl --context="$c" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NS}
  annotations:
    linkerd.io/inject: enabled
EOF
done

# --- workloads --------------------------------------------------------------

# Driven from WORKLOAD_TABLE in clusters/lib.sh rather than written out here:
#
#   app          federated, every cluster
#   api        flat mirror, every cluster -- each copy reachable as api-<cluster>
#   app-gateway  gateway mirror, east ONLY. The control case, not the main event.
#
# Anything that draws, measures or drives this app needs the same answer about
# which services exist where, and a second copy of the list is how the load
# generator ended up driving one service while the runner measured another --
# silently, as zero traffic for a mode nobody had exercised.
#
# `while read` fed by a here-string, not a pipe: a pipeline puts the loop in a
# subshell, where `set -e` inside deploy_svc cannot stop the run.
for name in $(clusters); do
  log "cluster '${name}': deploying workloads"
  while read -r w mode replicas key value; do
    [ -n "$w" ] || continue
    deploy_svc "$name" "$w" "$replicas" "$key" "$value"
    ok "  ${w} (${mode} — ${key}=${value})"
  done <<< "$(workloads_in "$name")"
done

# --- wait -------------------------------------------------------------------

log "waiting for workloads to become ready"
for name in $(clusters); do
  kubectl --context="$(ctx "$name")" -n "$APP_NS" \
    rollout status deploy --timeout=240s >/dev/null 2>&1 \
    || warn "cluster '${name}': some workloads are slow"
done

# --- report -----------------------------------------------------------------

echo
log "zone distribution (proves FM3 has somewhere to shift traffic)"
for name in $(clusters); do
  printf '\n--- %s ---\n' "$name"
  kubectl --context="$(ctx "$name")" -n "$APP_NS" get pods \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' \
    --no-headers 2>/dev/null | sort
done

echo
log "mirrored + federated services (may take ~30s to appear)"
for name in $(clusters); do
  printf '\n--- %s ---\n' "$name"
  kubectl --context="$(ctx "$name")" -n "$APP_NS" get svc --no-headers 2>/dev/null \
    | awk '{printf "  %-28s %s\n", $1, $3}'
done

cat <<EOF

Next: verify/multicluster.sh asserts that the federated service really has
endpoints from all three clusters, which is the functional proof that linking
worked (the host-side 'linkerd multicluster check' cannot tell you this).
EOF
