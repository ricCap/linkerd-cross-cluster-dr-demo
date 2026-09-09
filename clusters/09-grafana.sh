#!/usr/bin/env bash
# Grafana + a federating Prometheus, so the experiments can be *seen*.
#
# Two design decisions worth explaining:
#
# ONE DATASOURCE, NOT THREE
#   Each cluster runs its own linkerd-viz Prometheus. Rather than adding three
#   datasources and fighting mixed queries in every panel, we run one extra
#   Prometheus in west that federates from all three and stamps a `cluster`
#   label on everything. Every panel then splits by cluster from a single
#   datasource.
#
# REACHED VIA THE MESH'S OWN MIRRORED SERVICES
#   west cannot resolve east's Prometheus ClusterIP -- service CIDRs are not
#   routable across clusters, only pod CIDRs are. Rather than hardcoding pod IPs
#   (which change on every restart), we export each cluster's Prometheus as a
#   flat mirror and let Linkerd resolve it: prometheus-east.linkerd-viz, etc.
#   The observability stack rides on the very mechanism it is observing.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl helm

GRAFANA_NS="${GRAFANA_NS:-dr-observability}"
HOST_CLUSTER="${HOST_CLUSTER:-west}"
GRAFANA_PORT="${GRAFANA_PORT:-50760}"
CTX="$(ctx "$HOST_CLUSTER")"

SA_IDENTITY="dr-prometheus.${GRAFANA_NS}.serviceaccount.identity.linkerd.cluster.local"

# --- make sure linkerd-viz is actually meshed --------------------------------
#
# A pod that restarts while its cluster's proxy-injector is unavailable comes
# back WITHOUT a proxy -- 1/1 instead of 2/2 -- and Kubernetes reports it as
# perfectly Running. Linkerd's authorization policies are enforced by the proxy,
# so an unmeshed Prometheus silently serves /federate to anyone.
#
# That is not a hypothetical: it happened here after a cluster restart, and the
# only reason federation "worked" for one cluster was that its Prometheus had
# lost its proxy. Check for it explicitly rather than being pleased that the
# scrape succeeded.
for name in $(clusters); do
  c="$(ctx "$name")"
  unmeshed="$(kubectl --context="$c" -n linkerd-viz get pods --no-headers 2>/dev/null \
    | awk '$2 == "1/1" && $3 == "Running" {print $1}')"
  if [ -n "$unmeshed" ]; then
    warn "cluster '${name}': unmeshed linkerd-viz pods found (restarted without a proxy):"
    echo "$unmeshed" | sed 's/^/    /'
    log "  restarting linkerd-viz in '${name}' to restore injection"
    kubectl --context="$c" -n linkerd-viz rollout restart deploy >/dev/null 2>&1 || true
    kubectl --context="$c" -n linkerd-viz rollout status deploy --timeout=180s >/dev/null 2>&1 || true
    ok "  linkerd-viz remeshed"
  fi
done

# --- authorize the federating Prometheus -------------------------------------
#
# linkerd-viz ships the `prometheus-admin` Server with a default-deny policy
# that authorizes only the metrics-api identity. Our federating Prometheus is a
# different workload in a different namespace, so it gets a 403 -- correctly.
# Grant it explicitly rather than weakening the Server.
#
# This is applied to EVERY cluster, because west's dr-prometheus scrapes all
# three. The identity string is the same everywhere: all clusters share one
# trust anchor, which is the whole reason cross-cluster identity works at all.
for name in $(clusters); do
  log "cluster '${name}': authorizing ${SA_IDENTITY} to scrape prometheus-admin"
  kubectl --context="$(ctx "$name")" apply -f - >/dev/null <<EOF
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: dr-prometheus-federation
  namespace: linkerd-viz
spec:
  identities:
    - "${SA_IDENTITY}"
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: dr-prometheus-federation
  namespace: linkerd-viz
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: prometheus-admin
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: MeshTLSAuthentication
      name: dr-prometheus-federation
EOF
done

# --- authorize and expose the multicluster controllers -----------------------
#
# The service-mirror controllers are what probe each remote gateway, so they own
# `gateway_alive` and `gateway_probe_latency_ms` -- the only signals that can
# answer "is the gateway reachable", and the metric behind the write-up's
# "gateways available" row. Nothing was collecting them: linkerd-viz does not
# scrape the linkerd-multicluster namespace, and the controllers' admin port
# sits behind a default-deny `controller` Server, so probing it returns 403.
#
# Only HOST_CLUSTER is wired up, and that is enough by construction: a service
# mirror controller runs in the cluster that LINKS to a target, not in the
# target. west links to east-gw, so west holds the controller that probes that
# gateway -- the same cluster dr-prometheus lives in, which is why this needs no
# cross-cluster scrape credentials.
log "cluster '${HOST_CLUSTER}': authorizing ${SA_IDENTITY} to scrape the multicluster controllers"
kubectl --context="$CTX" apply -f - >/dev/null <<EOF
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: dr-prometheus-multicluster
  namespace: linkerd-multicluster
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: controller
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: MeshTLSAuthentication
      name: dr-prometheus-multicluster
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: dr-prometheus-multicluster
  namespace: linkerd-multicluster
spec:
  identities:
    - ${SA_IDENTITY}
---
# Headless on purpose. A ClusterIP would load-balance each scrape to whichever
# controller answered, so series would flip between controllers and every
# counter would look like it kept resetting. Headless makes DNS return every pod
# address, and dns_sd_configs scrapes each one.
apiVersion: v1
kind: Service
metadata:
  name: multicluster-controllers
  namespace: linkerd-multicluster
spec:
  clusterIP: None
  selector:
    component: controller
    linkerd.io/extension: multicluster
  ports:
    - name: ctrl-admin
      port: 9999
      targetPort: 9999
EOF

# --- export each cluster's Prometheus as a flat mirror -----------------------

for name in $(clusters); do
  [ "$name" != "$HOST_CLUSTER" ] || continue
  log "exporting ${name}'s Prometheus for cross-cluster federation"
  kubectl --context="$(ctx "$name")" -n linkerd-viz label svc prometheus \
    mirror.linkerd.io/exported=remote-discovery --overwrite >/dev/null
done

log "waiting for the mirrors to appear in ${HOST_CLUSTER}"
mirrors_ready() {
  local n
  for n in $(clusters); do
    [ "$n" != "$HOST_CLUSTER" ] || continue
    kubectl --context="$CTX" -n linkerd-viz get svc "prometheus-${n}" >/dev/null 2>&1 || return 1
  done
}
retry 24 5 mirrors_ready || warn "not all Prometheus mirrors appeared; federation may be incomplete"

# --- federating prometheus ---------------------------------------------------

kubectl --context="$CTX" create ns "$GRAFANA_NS" --dry-run=client -o yaml \
  | kubectl --context="$CTX" apply -f - >/dev/null

# Build the scrape config: the local Prometheus by ClusterIP, the remote ones by
# their mirrored service names.
scrape_configs=""
for name in $(clusters); do
  if [ "$name" = "$HOST_CLUSTER" ]; then
    target="prometheus.linkerd-viz.svc.cluster.local:9090"
  else
    target="prometheus-${name}.linkerd-viz.svc.cluster.local:9090"
  fi
  scrape_configs="${scrape_configs}
      - job_name: federate-${name}
        honor_labels: true
        metrics_path: /federate
        params:
          'match[]':
            - '{job=\"linkerd-proxy\"}'
            - '{job=\"linkerd-controller\"}'
            # Belt and braces. The job matchers above should already carry every
            # proxy series, but a metric that silently fails to federate costs a
            # whole experiment run to discover -- the panel is simply empty and
            # nothing says why. Name the series the dashboard cannot do without.
            # verify/dashboard.sh is what actually proves they arrived.
            - '{__name__=~\"outbound_http_balancer_endpoints|outbound_http_balancer_adaptive_endpoints|outbound_http_balancer_adaptive_load_average|outbound_http_balancer_adaptive_load_band_low|outbound_http_balancer_adaptive_load_band_high|response_latency_ms_bucket|control_identity_cert_expiration_timestamp_seconds\"}'
        static_configs:
          - targets: ['${target}']
            labels:
              cluster: ${name}"
done

scrape_configs="${scrape_configs}
      - job_name: multicluster-controllers
        dns_sd_configs:
          - names: ['multicluster-controllers.linkerd-multicluster.svc.cluster.local']
            type: A
            port: 9999
        relabel_configs:
          - target_label: cluster
            replacement: ${HOST_CLUSTER}"

# Recording and alerting rules. Deliberately Prometheus-managed rather than
# Grafana-managed: they are part of what a reader takes away, and a rule stored
# in Grafana's database does not travel. Grafana still lists them read-only
# under Alerting -> Alert rules -> Data source-managed, and the ALERTS series
# Prometheus emits while a rule is pending or firing is what the dashboard's
# alert timeline is drawn from.
#
# A malformed rule file is SILENTLY IGNORED by Prometheus -- it logs and starts
# anyway, with no rules and no error surfaced. verify/dashboard.sh checks that
# the groups actually loaded, which is the only reason that failure would ever
# be noticed before an experiment was wasted on it.
log "installing Prometheus alerting rules"
kubectl --context="$CTX" create configmap dr-prometheus-rules \
  --namespace "$GRAFANA_NS" \
  --from-file="${REPO_ROOT}/grafana/alert-rules.yml" \
  --dry-run=client -o yaml | kubectl --context="$CTX" apply -f - >/dev/null

# Roll the pod whenever the config or the rules change.
#
# Applying a ConfigMap does not restart anything and does not reload Prometheus.
# Without this, re-running the script appears to succeed while Prometheus keeps
# serving the OLD config indefinitely -- a new scrape job simply never appears,
# and the only symptom is a metric that "does not exist". That cost a debugging
# round here: the multicluster-controllers job was in the ConfigMap, the Service
# had endpoints, and Prometheus had no such scrape pool.
#
# A checksum annotation is deterministic where /-/reload is a waiting game: the
# kubelet takes up to a minute to project a changed ConfigMap into the mount, so
# a reload fired immediately after apply reloads the previous content. The cost
# is a TSDB reset on config change, which is why verify/dashboard.sh gates on
# the baseline windows having refilled before an experiment runs.
CONFIG_SUM="$(printf '%s' "${scrape_configs}" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
RULES_SUM="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "${REPO_ROOT}/grafana/alert-rules.yml")"

log "deploying federating Prometheus"
kubectl --context="$CTX" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dr-prometheus
  namespace: ${GRAFANA_NS}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dr-prometheus-config
  namespace: ${GRAFANA_NS}
data:
  prometheus.yml: |
    global:
      scrape_interval: 10s
      evaluation_interval: 10s
    rule_files:
      - /etc/prometheus/rules/*.yml
    scrape_configs:${scrape_configs}
---
# The measurement of a whole run lives in here, so it gets a volume.
#
# It used to mount exactly two configMaps and nothing else, which put /prometheus
# on the container's writable layer: ANY pod restart destroyed every measurement
# in the run, and nothing would have reported that it had happened. That is the
# FM4 observability lesson one level deeper -- it is not enough for the observer
# to sit outside the blast radius if the observer's STORAGE does not survive the
# observer.
#
# hostPath, NOT a PersistentVolumeClaim.
#
# The obvious fix is a PVC, and it does not work here: clusters/01-create-clusters.sh
# creates every cluster with --disable=traefik,local-storage, so there is no
# provisioner and no StorageClass at all. A PVC just sits Pending forever, and
# because the deployment waits on the pod, the whole build hangs at "waiting for
# Grafana and Prometheus" with no error naming the cause.
#
# A hostPath on the node solves the actual problem. The failure being fixed is
# that a POD restart destroyed the run -- and a hostPath survives that, because
# the directory lives on the k3d node container rather than in the pod. It does
# not survive losing the node, which is a real limit and an acceptable one here:
# the stack lives in west, and west is the cluster no experiment is allowed to
# touch. That is the same property verify/fm4-verify.sh refuses to run without.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dr-prometheus
  namespace: ${GRAFANA_NS}
spec:
  replicas: 1
  # Recreate, not RollingUpdate. The claim above is ReadWriteOnce, so a rolling
  # update would deadlock: the new pod cannot mount the volume until the old pod
  # releases it, and the old pod is not terminated until the new one is ready.
  strategy:
    type: Recreate
  selector:
    matchLabels: { app: dr-prometheus }
  template:
    metadata:
      labels: { app: dr-prometheus }
      annotations:
        linkerd.io/inject: enabled
        dr.checksum/config: "${CONFIG_SUM}"
        dr.checksum/rules: "${RULES_SUM}"
    spec:
      serviceAccountName: dr-prometheus
      initContainers:
        # A hostPath directory is created by the kubelet as root, mode 0755, and
        # prom/prometheus runs as nobody (65534). Without this the container
        # starts, fails to open its own TSDB, and CrashLoopBackOffs -- which
        # reads as "Prometheus is broken" rather than "the volume is not
        # writable". fsGroup does not help: it does not apply to hostPath.
        #
        # Plain initContainer, not a sidecar: it runs after Linkerd's native
        # sidecars have started, needs no network, and exits.
        - name: chown-data
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 65534:65534 /prometheus"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - { name: data, mountPath: /prometheus }
      containers:
        - name: prometheus
          image: prom/prometheus:v3.1.0
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            # 24h, not 6h. A full experiment sweep plus the write-up that reads
            # it does not fit in six hours, and the failure is silent: the
            # dashboard renders an empty window for a run that did happen, which
            # reads as "the experiment produced nothing". Retention has to
            # outlast the gap between running the fault and screenshotting it.
            # At 30 rps across three clusters this costs very little disk.
            - --storage.tsdb.retention.time=24h
            - --web.enable-lifecycle
            # Enabled HERE, at install time, and not later when it is wanted.
            # The snapshot API is the supported way to get a consistent copy of
            # the TSDB out, and turning it on requires editing the Deployment --
            # which triggers a rollout, which destroys the data you were trying
            # to snapshot. Last run it had to be copied out live with tar over
            # kubectl exec instead. There is no cost to having it on from the
            # start, and it cannot be added when you need it.
            - --web.enable-admin-api
          ports: [{ containerPort: 9090 }]
          volumeMounts:
            - { name: config, mountPath: /etc/prometheus }
            - { name: rules,  mountPath: /etc/prometheus/rules }
            - { name: data,   mountPath: /prometheus }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { memory: 1Gi }
      volumes:
        - name: config
          configMap: { name: dr-prometheus-config }
        - name: rules
          configMap: { name: dr-prometheus-rules }
        - name: data
          hostPath:
            path: /var/lib/dr-prometheus
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: dr-prometheus
  namespace: ${GRAFANA_NS}
spec:
  selector: { app: dr-prometheus }
  ports: [{ port: 9090, targetPort: 9090 }]
EOF

# --- grafana -----------------------------------------------------------------

log "preparing dashboards"

DASH_DIR="${REPO_ROOT}/clusters/.generated/dashboards"
rm -rf "$DASH_DIR"; mkdir -p "$DASH_DIR"
cp "${REPO_ROOT}/grafana/dr-dashboard.json" "$DASH_DIR/"

# Vendored grafana.com dashboards need rewriting before they can be file
# provisioned -- see grafana/prepare.py for why.
if [ -d "${REPO_ROOT}/grafana/vendor" ]; then
  python3 "${REPO_ROOT}/grafana/prepare.py" dr-prom \
    "${REPO_ROOT}/grafana/vendor" "$DASH_DIR"
fi

DASH_SUM="$(cat "$DASH_DIR"/*.json | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"

log "deploying Grafana"
# Two ConfigMaps: the vendored dashboards are large (the HAZL one alone is
# ~150KB) and a single map would crowd the 1MB object limit.
kubectl --context="$CTX" create configmap dr-dashboards \
  --namespace "$GRAFANA_NS" \
  --from-file="${DASH_DIR}/dr-dashboard.json" \
  --dry-run=client -o yaml | kubectl --context="$CTX" apply -f - >/dev/null

vendored_files=""
for f in "$DASH_DIR"/*.json; do
  [ "$(basename "$f")" != "dr-dashboard.json" ] || continue
  vendored_files="${vendored_files} --from-file=$f"
done
if [ -n "$vendored_files" ]; then
  # shellcheck disable=SC2086
  kubectl --context="$CTX" create configmap dr-dashboards-vendor \
    --namespace "$GRAFANA_NS" $vendored_files \
    --dry-run=client -o yaml | kubectl --context="$CTX" apply -f - >/dev/null
else
  kubectl --context="$CTX" create configmap dr-dashboards-vendor \
    --namespace "$GRAFANA_NS" --from-literal=.keep="" \
    --dry-run=client -o yaml | kubectl --context="$CTX" apply -f - >/dev/null
fi

kubectl --context="$CTX" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dr-grafana-provisioning
  namespace: ${GRAFANA_NS}
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: dr-prometheus
        type: prometheus
        uid: dr-prom
        access: proxy
        url: http://dr-prometheus.${GRAFANA_NS}.svc.cluster.local:9090
        isDefault: true
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: dr
        folder: 'Disaster Recovery'
        type: file
        options:
          path: /var/lib/grafana/dashboards
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: ${GRAFANA_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: grafana }
  template:
    metadata:
      labels: { app: grafana }
      annotations:
        # Same trap as dr-prometheus: applying a ConfigMap neither restarts the
        # pod nor reloads the file, so a redeploy appeared to succeed while
        # Grafana kept serving the previous dashboard. Roll on content change.
        dr.checksum/dashboards: "${DASH_SUM}"
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:11.6.0
          env:
            # Anonymous admin: this is a throwaway local demo, and making people
            # log in to look at a chart during an incident drill is friction for
            # no benefit. Do not copy this into anything real.
            - { name: GF_AUTH_ANONYMOUS_ENABLED,  value: "true" }
            - { name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: "Admin" }
            - { name: GF_AUTH_BASIC_ENABLED,      value: "false" }
            - { name: GF_SECURITY_ALLOW_EMBEDDING, value: "true" }
          ports: [{ containerPort: 3000 }]
          volumeMounts:
            - { name: provisioning-ds, mountPath: /etc/grafana/provisioning/datasources }
            - { name: provisioning-db, mountPath: /etc/grafana/provisioning/dashboards }
            - { name: dashboards,      mountPath: /var/lib/grafana/dashboards }
            - { name: dashboards-vendor, mountPath: /var/lib/grafana/dashboards/vendor }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { memory: 512Mi }
      volumes:
        - name: provisioning-ds
          configMap:
            name: dr-grafana-provisioning
            items: [{ key: datasources.yaml, path: datasources.yaml }]
        - name: provisioning-db
          configMap:
            name: dr-grafana-provisioning
            items: [{ key: dashboards.yaml, path: dashboards.yaml }]
        - name: dashboards
          configMap: { name: dr-dashboards }
        - name: dashboards-vendor
          configMap: { name: dr-dashboards-vendor }
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: ${GRAFANA_NS}
spec:
  selector: { app: grafana }
  ports: [{ port: 3000, targetPort: 3000 }]
EOF

log "waiting for Grafana and Prometheus"
kubectl --context="$CTX" -n "$GRAFANA_NS" rollout status deploy/dr-prometheus --timeout=180s >/dev/null 2>&1 \
  || warn "dr-prometheus slow to start"
kubectl --context="$CTX" -n "$GRAFANA_NS" rollout status deploy/grafana --timeout=180s >/dev/null 2>&1 \
  || warn "grafana slow to start"

# --- verify federation is actually working -----------------------------------

log "checking that federation is returning data from all three clusters"
check_federation() {
  kubectl --context="$CTX" -n "$GRAFANA_NS" exec deploy/dr-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=count(count(response_total)by(cluster))' 2>/dev/null \
    | grep -q '"value":\[[0-9.]*,"3"\]'
}
if retry 18 10 check_federation; then
  ok "federation live: metrics present from all 3 clusters"
else
  warn "federation is not returning all 3 clusters yet -- check dr-prometheus targets:
  kubectl --context=${CTX} -n ${GRAFANA_NS} port-forward deploy/dr-prometheus 9090:9090
  then open http://localhost:9090/targets"
fi

cat <<EOF

Grafana is deployed. Expose it with:

  kubectl --context=${CTX} -n ${GRAFANA_NS} port-forward svc/grafana ${GRAFANA_PORT}:3000

  -> http://localhost:${GRAFANA_PORT}  (anonymous admin, no login)

The 'Disaster Recovery' folder holds the cross-cluster dashboard. Linkerd's
official dashboards can be imported from the Grafana UI by ID against the same
datasource: 15474 (Top Line), 15475 (Deployment), 15486 (Health).
EOF
