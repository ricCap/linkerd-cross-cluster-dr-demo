#!/usr/bin/env bash
# Live view of the thing this whole repo is about: where is traffic actually
# going, right now, across clusters and zones -- and is it still mTLS'd?
#
#   verify/watch.sh            refresh every 5s until Ctrl-C
#   verify/watch.sh once       print a single snapshot
#
# Reads the load generators' own proxy metrics. Traffic is attributed to a
# cluster by mapping target_ip against the pod CIDR table in lib.sh, because
# Linkerd does not put a cluster label on remote-discovery endpoints -- the pod
# IP is the only thing that identifies which cluster served the request.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl linkerd

INTERVAL="${INTERVAL:-5}"
ONCE="${1:-}"


snapshot() {
  printf '\033[H\033[2J'
  printf '\033[1mCross-cluster traffic — %s\033[0m\n' "$(date '+%H:%M:%S')"
  printf 'source of truth: each loadgen pod'\''s linkerd-proxy metrics (cumulative)\n\n'

  for src in $(clusters); do
    local metrics
    metrics="$(linkerd --context="$(ctx "$src")" diagnostics proxy-metrics \
      -n "$APP_NS" deploy/loadgen 2>/dev/null | grep '^response_total{' || true)"

    if [ -z "$metrics" ]; then
      printf '\033[1;33m%s\033[0m  (no metrics yet)\n\n' "$src"
      continue
    fi

    printf '\033[1;36m== from %s ==\033[0m\n' "$src"

    # Per exposure mode: totals, error count, and where the bytes went.
    # From modes_for, not hardcoded. The mirror names are not uniform across
    # clusters -- east resolves app-flat-west and has no gateway link -- so a fixed
    # list silently omits east's flat mirror from the live view, which is the
    # same class of error the README warns about under "flat mirroring uses a
    # different label than you think".
    for mode in $(modes_for "$src" | awk '{print $2}'); do
      local rows total errors dist tls_bad
      rows="$(echo "$metrics" | grep "authority=\"${mode}\." || true)"
      [ -n "$rows" ] || continue

      total=0; errors=0; tls_bad=0; dist=""

      # Aggregate counts by destination cluster and status.
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        local n ip code tls c
        n="${line##* }"
        n="${n%%.*}"
        ip="$(echo "$line" | sed -n 's/.*target_ip="\([^"]*\)".*/\1/p')"
        code="$(echo "$line" | sed -n 's/.*status_code="\([^"]*\)".*/\1/p')"
        tls="$(echo "$line" | sed -n 's/.*tls="\([^"]*\)".*/\1/p')"

        total=$((total + n))
        case "$code" in 2*) ;; *) errors=$((errors + n));; esac
        [ "$tls" = "true" ] || tls_bad=$((tls_bad + n))

        c="$(cluster_of_ip "$ip")"
        dist="${dist}${c} ${n}
"
      done <<< "$rows"

      # Collapse the per-endpoint rows into per-cluster totals.
      local summary
      summary="$(echo "$dist" | awk 'NF {a[$1]+=$2} END {for (k in a) printf "%s=%d ", k, a[k]}')"

      local err_color='\033[1;32m'
      [ "$errors" -gt 0 ] && err_color='\033[1;31m'
      local tls_note=""
      [ "$tls_bad" -gt 0 ] && tls_note=" \033[1;31m[${tls_bad} NOT mTLS]\033[0m"

      printf "  %-20s %7d reqs  ${err_color}%d err\033[0m  %s%b\n" \
        "$mode" "$total" "$errors" "$summary" "$tls_note"
    done
    echo
  done

  printf '\033[2mendpoint pool (app-federated, ready) — the federation membership signal\033[0m\n'
  for src in $(clusters); do
    local n
    n="$(linkerd --context="$(ctx "$src")" diagnostics proxy-metrics \
      -n "$APP_NS" deploy/loadgen 2>/dev/null \
      | awk -F' ' '/^outbound_http_balancer_endpoints\{endpoint_state="ready".*app-federated/ {print $NF}' \
      | head -1)"
    printf '  %-9s %s\n' "$src" "${n:-n/a}"
  done
}

if [ "$ONCE" = "once" ]; then
  snapshot
  exit 0
fi

trap 'printf "\033[?25h\n"; exit 0' INT TERM
printf '\033[?25l'
while true; do
  snapshot
  sleep "$INTERVAL"
done
