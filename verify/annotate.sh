#!/usr/bin/env bash
# Post an annotation to Grafana so the dashboards show WHEN each fault happened.
#
#   verify/annotate.sh point  "FM2: partitioned east"           [extra-tag...]
#   verify/annotate.sh start  "FM2 hard"                        -> prints a token
#   verify/annotate.sh end    <token> "FM2 hard"                -> shades the window
#
# A screenshot of a chart with an unexplained cliff in it is not evidence of
# anything. A screenshot with a shaded region labelled "east partitioned" is.
# The region form is what makes the experiment legible to a reader.
#
# Silently does nothing if Grafana is not deployed, so experiment runners can
# call it unconditionally without special-casing.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

GRAFANA_NS="${GRAFANA_NS:-dr-observability}"
HOST_CLUSTER="${HOST_CLUSTER:-west}"
CTX="$(ctx "$HOST_CLUSTER")"

ACTION="${1:-}"; shift || true

# All calls go through a kubectl exec into the Grafana pod, so this works
# without a port-forward and without assuming anything about the host.
grafana_api() {
  local method="$1" path="$2" body="${3:-}"
  local pod
  pod="$(kubectl --context="$CTX" -n "$GRAFANA_NS" get pod -l app=grafana \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$pod" ] || return 1

  if [ -n "$body" ]; then
    kubectl --context="$CTX" -n "$GRAFANA_NS" exec "$pod" -- \
      wget -qO- --header='Content-Type: application/json' \
      --post-data="$body" "http://localhost:3000${path}" 2>/dev/null
  else
    kubectl --context="$CTX" -n "$GRAFANA_NS" exec "$pod" -- \
      wget -qO- "http://localhost:3000${path}" 2>/dev/null
  fi
}

# Grafana wants epoch milliseconds.
now_ms() { echo "$(( $(date +%s) * 1000 ))"; }

tags_json() {
  local out='"dr"' t
  for t in "$@"; do out="${out},\"${t}\""; done
  echo "[${out}]"
}

case "$ACTION" in
  point)
    text="$1"; shift || true
    body="{\"time\":$(now_ms),\"text\":$(printf '%s' "$text" | sed 's/"/\\"/g; s/^/"/; s/$/"/'),\"tags\":$(tags_json "$@")}"
    grafana_api POST /api/annotations "$body" >/dev/null 2>&1 \
      && ok "annotated: ${text}" || true
    ;;

  start)
    # Just emit the start time; `end` turns it into a region.
    now_ms
    ;;

  end)
    start_ms="$1"; text="$2"; shift 2 || true
    [ -n "$start_ms" ] || exit 0
    body="{\"time\":${start_ms},\"timeEnd\":$(now_ms),\"text\":$(printf '%s' "$text" | sed 's/"/\\"/g; s/^/"/; s/$/"/'),\"tags\":$(tags_json "$@")}"
    grafana_api POST /api/annotations "$body" >/dev/null 2>&1 \
      && ok "annotated window: ${text}" || true
    ;;

  *)
    die "usage: annotate.sh <point|start|end> ..."
    ;;
esac
