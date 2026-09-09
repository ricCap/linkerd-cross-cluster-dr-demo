#!/usr/bin/env bash
# Replay an archived Prometheus TSDB with a local Grafana, after the clusters are gone.
#
#   grafana/archive-stack.sh up [tarball]
#   grafana/archive-stack.sh down
#
# WHY THIS EXISTS
#
# The dashboards live in a Grafana running inside `west`. `task down` destroys
# it, and with it the only way to look at a run's charts -- while the numbers
# themselves survive perfectly well in results/ and in the TSDB archive. Without
# this, "we can screenshot it later" is false for every Grafana panel, and you
# find that out after the clusters are gone.
#
# The dashboard JSON is in this directory and the TSDB is a tarball, so the whole
# stack is reconstructable offline. Nothing here touches a cluster.
#
# NOTE the data path: the TSDB is at `prometheus/data` inside the tarball, not
# `prometheus/`. Mounting one level too high makes Prometheus initialise an empty
# database in the wrong directory and report zero metrics -- which looks exactly
# like a corrupt archive. That cost a debugging cycle; it is why this script
# resolves the path rather than letting the caller guess.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_DIR="${ARCHIVE_DIR:-${REPO_ROOT}/prometheus-archive}"
WORK="${ARCHIVE_DIR}/.stack"
NET=dr-archive
PROM=dr-archive-prom
GRAF=dr-archive-grafana
GRAF_PORT="${GRAF_PORT:-50761}"
PROM_PORT="${PROM_PORT:-9099}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-up}" in
  up)
    tarball="${2:-$(ls -t "${ARCHIVE_DIR}"/tsdb-*.tar 2>/dev/null | head -1)}"
    [ -n "$tarball" ] && [ -f "$tarball" ] || die "no TSDB archive found in ${ARCHIVE_DIR}"
    log "archive: $(basename "$tarball")"

    rm -rf "$WORK"; mkdir -p "$WORK"
    tar xf "$tarball" -C "$WORK"

    # Resolve the real TSDB directory rather than assuming a layout.
    data="$(dirname "$(find "$WORK" -maxdepth 3 -type d -name wal | head -1)")"
    [ -n "$data" ] || die "no TSDB found in the archive (looked for a wal/ directory)"
    ok "tsdb at ${data#$WORK/}"

    docker network create "$NET" >/dev/null 2>&1 || true
    docker rm -f "$PROM" "$GRAF" >/dev/null 2>&1 || true

    log "starting prometheus against the archive"
    docker run -d --name "$PROM" --network "$NET" -p "${PROM_PORT}:9090" \
      -v "${data}:/prometheus" \
      prom/prometheus:v3.1.0 \
      --config.file=/etc/prometheus/prometheus.yml \
      --storage.tsdb.path=/prometheus >/dev/null

    # Provision Grafana with the dashboards from this directory. Anonymous admin,
    # same as the in-cluster instance, because this is a throwaway reader.
    mkdir -p "$WORK/prov/datasources" "$WORK/prov/dashboards" "$WORK/dash"
    cp "${REPO_ROOT}/grafana/"*.json "$WORK/dash/" 2>/dev/null || true
    cat > "$WORK/prov/datasources/ds.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://${PROM}:9090
    isDefault: true
EOF
    cat > "$WORK/prov/dashboards/dash.yml" <<'EOF'
apiVersion: 1
providers:
  - name: archive
    type: file
    options: { path: /var/lib/grafana/dashboards }
EOF

    log "starting grafana"
    docker run -d --name "$GRAF" --network "$NET" -p "${GRAF_PORT}:3000" \
      -e GF_AUTH_ANONYMOUS_ENABLED=true \
      -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
      -e GF_AUTH_BASIC_ENABLED=false \
      -e GF_SECURITY_ALLOW_EMBEDDING=true \
      -v "$WORK/prov/datasources:/etc/grafana/provisioning/datasources:ro" \
      -v "$WORK/prov/dashboards:/etc/grafana/provisioning/dashboards:ro" \
      -v "$WORK/dash:/var/lib/grafana/dashboards:ro" \
      grafana/grafana:11.6.0 >/dev/null

    log "waiting for both to answer"
    for i in $(seq 1 40); do
      curl -fsS -m 3 "http://localhost:${PROM_PORT}/-/ready" >/dev/null 2>&1 && break; sleep 3
    done
    for i in $(seq 1 40); do
      curl -fsS -m 3 "http://localhost:${GRAF_PORT}/api/health" >/dev/null 2>&1 && break; sleep 3
    done

    # Verify with a TIME-INDEPENDENT query, and never an instant one.
    #
    # `count(count by (__name__)(...))` evaluated at "now" only sees series with
    # a sample inside the 5m staleness window. An archive is by definition old,
    # so that number decays as real time passes and eventually reads 0 -- which
    # is indistinguishable from a corrupt archive. Measured on this very
    # archive: 617 when queried minutes after it was taken, 271 eleven minutes
    # later, and it keeps falling. The label endpoint has no such window.
    series="$(curl -s -m 15 "http://localhost:${PROM_PORT}/api/v1/label/__name__/values" \
      | tr ',' '\n' | grep -c '"' || true)"
    [ "${series:-0}" -gt 0 ] || die "archive replayed no metrics"
    ok "${series} distinct metric names recovered"

    # The run window, read off the data rather than guessed, because a dashboard
    # pointed at "now" shows empty panels and looks like a broken archive.
    bounds="$(curl -s -m 20 "http://localhost:${PROM_PORT}/api/v1/query_range" \
      --data-urlencode 'query=sum(rate(response_total[2m]))' \
      --data-urlencode "start=$(( $(date +%s) - 172800 ))" \
      --data-urlencode "end=$(date +%s)" \
      --data-urlencode 'step=60' \
      | tr '[' '\n' | grep -o '^[0-9]\{10\}' | sort -n)"
    first="$(echo "$bounds" | head -1)"; last="$(echo "$bounds" | tail -1)"

    ok "grafana    -> http://localhost:${GRAF_PORT}  (anonymous admin)"
    ok "prometheus -> http://localhost:${PROM_PORT}"
    if [ -n "$first" ] && [ -n "$last" ]; then
      ok "data window -> $(date -r "$first" '+%Y-%m-%d %H:%M') .. $(date -r "$last" '+%H:%M') local"
      printf '\nOpen the dashboard already scoped to the run, so the panels have data:\n\n  http://localhost:%s/d/dr-crosscluster/?from=%s000&to=%s000\n\n' \
        "$GRAF_PORT" "$first" "$last"
    else
      printf '\nSet the time picker to the run window; the dashboards default to a live\nrange and will correctly show nothing.\n'
    fi
    ;;

  down)
    docker rm -f "$PROM" "$GRAF" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
    ok "archive stack removed"
    ;;

  *) die "usage: archive-stack.sh <up|down> [tarball]" ;;
esac
