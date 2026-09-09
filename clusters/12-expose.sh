#!/usr/bin/env bash
# Expose Grafana (and the status page's needs) to the host, stably.
#
#   clusters/12-expose.sh up
#   clusters/12-expose.sh down
#   clusters/12-expose.sh status
#
# WHY NOT `kubectl port-forward`
#
# Docker Desktop on macOS gives the host no route to the Docker bridge network,
# so 172.28.0.0/16 is unreachable and only PUBLISHED container ports work. The
# usual workaround is `kubectl port-forward`, which is what `task grafana:open`
# did -- and it has two problems, one cosmetic and one that corrupts results.
#
#   1. It is flaky. Observed repeatedly here: the forward serves for a while,
#      then returns "error creating error stream ... Timeout occurred" while
#      every pod stays Running. It multiplexes over SPDY streams through the
#      API server and those streams time out under load.
#
#   2. It routes through WEST'S API SERVER. So the dashboard is only as
#      reachable as west's control plane -- and FM4 *measures* dashboard
#      availability as one of its checks. A flapping forward reads exactly like
#      "the observability stack died with the region", which is a false
#      positive on the most interesting check in the experiment.
#
# This path instead publishes a host port from a relay container attached to
# dr-net, forwarding to a NodePort on west. The API server is no longer in the
# path: what is being tested is whether GRAFANA is up, which is the question
# FM4 is actually asking.
#
# The relay is a separate NodePort Service rather than a patch of the one
# 09-grafana.sh manages, so re-running the installer does not fight this.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need docker kubectl

# west, because that is where the observability stack lives and no experiment
# touches it. Derived rather than hardcoded so this follows the stack if it moves.
HOST_CLUSTER="${HOST_CLUSTER:-west}"
GRAFANA_NS="${GRAFANA_NS:-dr-observability}"
GRAFANA_PORT="${GRAFANA_PORT:-50760}"
GRAFANA_NODEPORT="${GRAFANA_NODEPORT:-30760}"
RELAY_NAME="dr-expose-grafana"
RELAY_IMAGE="${RELAY_IMAGE:-alpine/socat:latest}"

# The status page is a static directory, so it needs no cluster access at all --
# but `task viz` served it with a foreground python http.server, which dies with
# the terminal that started it. Serving it from a restart-policied container
# instead means the page outlives the shell, which matters when an experiment
# runs longer than the session you started it in.
#
# The SAMPLER still runs on the host: it needs kubectl and the linkerd CLI to
# read proxy metrics. Only the serving moves.
VIZ_NAME="dr-expose-viz"
VIZ_PORT="${VIZ_PORT:-8731}"
VIZ_IMAGE="${VIZ_IMAGE:-nginx:alpine}"

node_ip() {
  docker inspect "k3d-${HOST_CLUSTER}-server-0" \
    -f "{{(index .NetworkSettings.Networks \"${DOCKER_NET}\").IPAddress}}" 2>/dev/null
}

case "${1:-up}" in
  up)
    c="$(ctx "$HOST_CLUSTER")"

    log "publishing grafana as a NodePort on '${HOST_CLUSTER}'"
    kubectl --context="$c" -n "$GRAFANA_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: grafana-nodeport
  labels:
    app: grafana
    dr.exposure: host
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - name: http
      port: 3000
      targetPort: 3000
      nodePort: ${GRAFANA_NODEPORT}
EOF
    ok "  nodePort ${GRAFANA_NODEPORT}"

    ip="$(node_ip)"
    [ -n "$ip" ] || die "could not read the node address for '${HOST_CLUSTER}'"

    # Recreate rather than reuse: the node address can change across a rebuild,
    # and a relay pointed at a stale address fails in the silent way -- it
    # accepts the connection and then hangs.
    docker rm -f "$RELAY_NAME" >/dev/null 2>&1 || true

    log "starting relay ${RELAY_NAME}: host :${GRAFANA_PORT} -> ${ip}:${GRAFANA_NODEPORT}"
    docker run -d --name "$RELAY_NAME" \
      --network "$DOCKER_NET" \
      --restart unless-stopped \
      -p "${GRAFANA_PORT}:3000" \
      "$RELAY_IMAGE" \
      "tcp-listen:3000,fork,reuseaddr" "tcp-connect:${ip}:${GRAFANA_NODEPORT}" >/dev/null

    log "waiting for grafana to answer through the relay"
    up() { curl -fsS -m 3 "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; }
    if retry 20 2 up; then
      ok "grafana -> http://localhost:${GRAFANA_PORT}  (anonymous admin, no login)"
    else
      warn "relay is running but grafana did not answer within 40s"
      docker logs --tail 10 "$RELAY_NAME" 2>&1 | sed 's/^/    /'
    fi

    docker rm -f "$VIZ_NAME" >/dev/null 2>&1 || true
    log "serving the status page from ${REPO_ROOT}/viz"
    docker run -d --name "$VIZ_NAME" \
      --restart unless-stopped \
      -p "${VIZ_PORT}:80" \
      -v "${REPO_ROOT}/viz:/usr/share/nginx/html:ro" \
      "$VIZ_IMAGE" >/dev/null

    viz_up() { curl -fsS -m 3 "http://localhost:${VIZ_PORT}/" >/dev/null 2>&1; }
    if retry 15 2 viz_up; then
      ok "status page -> http://localhost:${VIZ_PORT}"
      log "  the sampler still runs on the host: task viz:sample"
    else
      warn "status page did not answer within 30s"
      docker logs --tail 10 "$VIZ_NAME" 2>&1 | sed 's/^/    /'
    fi
    ;;

  down)
    # Names this container has had. A rename orphans every container still
    # carrying the old one: `down` stops matching them, so they sit there
    # forever and no teardown can reach them. dr-expose-site was left running
    # for nine days exactly this way.
    #
    # Deliberately NOT including dr-archive-grafana / dr-archive-prom. Those
    # mount prometheus-archive/ and hold a recorded run's TSDB -- they are an
    # artifact, not a leftover, and they have their own `task archive:down`.
    # Removing measurements as a side effect of tearing down clusters is the
    # kind of silent data loss this repo exists to complain about.
    # Report what was actually removed.
    #
    # `docker rm -f` is idempotent -- it exits 0 for a container that does not
    # exist -- so `rm -f X && ok "removed"` prints "removed" every time, whether
    # or not anything was there. Small, but it is the same shape as the bugs
    # this repo keeps finding: a success message for work that did not happen.
    # Ask whether it exists first.
    gone() { ! docker container inspect "$1" >/dev/null 2>&1; }
    for name in dr-expose-site "$VIZ_NAME" "$RELAY_NAME"; do
      if gone "$name"; then
        log "no ${name} running"
      else
        docker rm -f "$name" >/dev/null 2>&1 || true
        if gone "$name"; then ok "removed ${name}"; else warn "could not remove ${name}"; fi
      fi
    done
    kubectl --context="$(ctx "$HOST_CLUSTER")" -n "$GRAFANA_NS" \
      delete svc grafana-nodeport --ignore-not-found >/dev/null 2>&1 || true
    # Same idempotency trap as the containers above, plus a second one: this
    # runs during teardown, when the API server may already be gone, and
    # `|| true` swallows that too. So it cannot claim the Service was removed --
    # only that it is not there now, which is all the caller needs and all this
    # can honestly establish.
    if kubectl --context="$(ctx "$HOST_CLUSTER")" -n "$GRAFANA_NS" \
         get svc grafana-nodeport >/dev/null 2>&1; then
      warn "nodePort service still present"
    else
      ok "no nodePort service"
    fi
    ;;

  status)
    printf '  %-22s ' "relay container"
    docker ps --filter "name=${RELAY_NAME}" --format '{{.Status}} ({{.Ports}})' 2>/dev/null | head -1 \
      || echo "not running"
    printf '  %-22s ' "grafana via host"
    if curl -fsS -m 3 "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
      echo "http://localhost:${GRAFANA_PORT}  OK"
    else
      echo "NOT answering on :${GRAFANA_PORT}"
    fi
    printf '  %-22s ' "status page"
    if curl -fsS -m 3 "http://localhost:${VIZ_PORT}/" >/dev/null 2>&1; then
      echo "http://localhost:${VIZ_PORT}  OK"
    else
      echo "NOT answering on :${VIZ_PORT}"
    fi
    ;;

  *)
    die "usage: 12-expose.sh <up|down|status>"
    ;;
esac
