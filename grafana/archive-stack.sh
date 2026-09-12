#!/usr/bin/env bash
# Replay an archived Prometheus TSDB with a local Grafana, after the clusters are gone.
#
#   grafana/archive-stack.sh up [tarball]     (or TARBALL=... , or newest found)
#   grafana/archive-stack.sh down
#
# A run is two files: tsdb-<stamp>.tar[.gz] and annotations-<stamp>.json beside
# it. The TSDB holds the series; the annotations hold the red fault regions,
# which live in Grafana's database and so travel separately. Both are written by
# `task archive:save`, and `task archive:fetch` downloads the published pair.
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
# Pinned, not arbitrary: dr-dashboard.json binds every panel to this uid.
DS_UID=dr-prom

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
# Named warn_line, not warn: this script is standalone and does not source
# clusters/lib.sh, and a bare `warn` reads like the one defined there.
warn_line() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }

case "${1:-up}" in
  up)
    # `tsdb-*.tar*` rather than `tsdb-*.tar`: the published archive is gzipped
    # to keep the release asset small, and `tar xf` detects that on its own.
    tarball="${2:-${TARBALL:-$(ls -t "${ARCHIVE_DIR}"/tsdb-*.tar* 2>/dev/null | head -1 || true)}}"
    [ -n "$tarball" ] && [ -f "$tarball" ] || die "no TSDB archive found in ${ARCHIVE_DIR}
     Fetch the published one with 'task archive:fetch', or take your own from a
     live rig with 'task archive:save' BEFORE 'task down'."
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

    # The vendored grafana.com dashboards, for parity with the in-cluster
    # Grafana. They need rewriting before file provisioning will bind them --
    # see grafana/prepare.py. Skipped without python3 rather than failing: the
    # dashboard this script exists for is dr-dashboard.json, which needs none.
    if [ -d "${REPO_ROOT}/grafana/vendor" ] && command -v python3 >/dev/null 2>&1; then
      python3 "${REPO_ROOT}/grafana/prepare.py" "$DS_UID" \
        "${REPO_ROOT}/grafana/vendor" "$WORK/dash" >/dev/null 2>&1 || true
    fi

    # uid MUST be dr-prom, and the name MUST match the in-cluster datasource.
    #
    # Every panel in dr-dashboard.json carries `"datasource": {"uid": "dr-prom"}`
    # -- 17 of them -- because that is what clusters/09-grafana.sh provisions.
    # A datasource here under any other uid is not found, and Grafana renders
    # "Datasource dr-prom was not found" on every panel. That failure looks
    # exactly like a corrupt archive, which is the one thing this script goes
    # out of its way to be able to rule out. It is the same trap prepare.py
    # documents for the vendored dashboards, one level up.
    cat > "$WORK/prov/datasources/ds.yml" <<EOF
apiVersion: 1
datasources:
  - name: dr-prometheus
    uid: ${DS_UID}
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

    # --- the red fault regions -----------------------------------------------
    #
    # Annotations are the one part of a run that the TSDB does NOT carry.
    # verify/annotate.sh posts them to Grafana's own database, so `task down`
    # destroys them along with the Grafana that held them, and the replay comes
    # up with unshaded charts. annotate.sh's header is the argument for why that
    # matters: "A screenshot of a chart with an unexplained cliff in it is not
    # evidence of anything." The dashboard's first text panel then tells a
    # reader to look for red regions that are not there.
    #
    # `task archive:save` writes them beside the tarball as
    # annotations-<stamp>.json; this pushes them back in. They go in as
    # ORGANIZATION annotations, with no dashboardUID -- that is what the
    # dashboard's "Experiments" query matches (by tag `dr`), and what
    # annotate.sh produced in the first place.
    #
    # Every failure here is soft. An archive taken before this existed has no
    # sidecar file, and it must still replay.
    stem="$(basename "$tarball")"; stem="${stem#tsdb-}"; stem="${stem%%.tar*}"
    annots="${ARCHIVE_DIR}/annotations-${stem}.json"
    # `|| true` because of `pipefail` at the top: a non-matching glob makes `ls`
    # exit 1, pipefail hands that status to the whole pipeline, and `set -e`
    # kills the script -- silently, with the containers up and no URL printed.
    # That is the same class of failure as the bounds query below.
    [ -f "$annots" ] || annots="$(ls -t "${ARCHIVE_DIR}"/annotations-*.json 2>/dev/null | head -1 || true)"

    if [ -n "${annots:-}" ] && [ -f "$annots" ]; then
      if command -v python3 >/dev/null 2>&1; then
        restored="$(python3 - "$annots" "http://localhost:${GRAF_PORT}" <<'PYEOF'
import json, sys, urllib.request

src, base = sys.argv[1], sys.argv[2]
try:
    items = json.load(open(src))
except Exception:
    print(0); raise SystemExit

n = 0
for a in items if isinstance(items, list) else []:
    if not a.get("time"):
        continue
    # Only the fields that define the marker. Grafana rejects a POST carrying
    # an `id` from another instance, and dashboardId/panelId from the old
    # Grafana point at rows that do not exist in this one.
    body = {"time": a["time"], "text": a.get("text", ""), "tags": a.get("tags") or ["dr"]}
    if a.get("timeEnd") and a["timeEnd"] != a["time"]:
        body["timeEnd"] = a["timeEnd"]
    req = urllib.request.Request(
        base + "/api/annotations",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=10).read()
        n += 1
    except Exception:
        pass
print(n)
PYEOF
)" || restored=0
        if [ "${restored:-0}" -gt 0 ]; then
          ok "${restored} fault annotations restored from $(basename "$annots")"
        else
          warn_line "annotations file present but none could be restored -- charts will be unshaded"
        fi
      else
        warn_line "python3 not found: skipping annotations, the fault regions will be missing"
      fi
    else
      warn_line "no annotations file beside this archive -- the red fault regions will be missing.
     Newer archives carry one; 'task archive:save' writes it."
    fi

    # The run window, read off the data rather than guessed, because a dashboard
    # pointed at "now" shows empty panels and looks like a broken archive.
    #
    # `|| true` is load-bearing under `set -e`. When the archive holds no
    # response_total -- a partial archive, or one taken before load started --
    # the grep matches nothing, exits 1, and takes the whole script with it:
    # silently, one line before the Grafana URL is printed, with both containers
    # left running. The `else` branch below was written for exactly that case
    # and could never be reached. Losing the window is a degraded result, not a
    # failure; the stack is up either way and the reader still needs the link.
    bounds="$(curl -s -m 20 "http://localhost:${PROM_PORT}/api/v1/query_range" \
      --data-urlencode 'query=sum(rate(response_total[2m]))' \
      --data-urlencode "start=$(( $(date +%s) - 172800 ))" \
      --data-urlencode "end=$(date +%s)" \
      --data-urlencode 'step=60' \
      | tr '[' '\n' | grep -o '^[0-9]\{10\}' | sort -n || true)"
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
