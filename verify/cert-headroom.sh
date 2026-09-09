#!/usr/bin/env bash
# Certificate headroom across the data plane.
#
#   verify/cert-headroom.sh [cluster]     one cluster
#   verify/cert-headroom.sh all           every cluster
#
# Reads control_identity_cert_expiration_timestamp_seconds from each meshed
# workload's proxy and reports how long it has left.
#
# This is the metric that turns "the control plane is down" from a vague worry
# into a number. With linkerd-identity unavailable, a running proxy keeps
# working until its current certificate expires -- and this says exactly when
# that is. It is also the FM5 canary: a trust anchor that is about to expire is
# a global outage with a countdown on it, and unlike every other failure in this
# repo there is no cluster to fail over to.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl linkerd

TARGET="${1:-all}"
NOW="$(date +%s)"

report_cluster() {
  local name="$1" c workloads w exp remain
  c="$(ctx "$name")"

  printf '\n\033[1m--- %s ---\033[0m\n' "$name"
  printf '%-28s %-12s %s\n' WORKLOAD 'EXPIRES IN' 'AT'
  printf -- '---------------------------------------------------------------\n'

  # `kubectl get deploy -o name` emits `deployment.apps/foo`, which the linkerd
  # CLI rejects ("cannot find Kubernetes canonical name from friendly name
  # [deployment.apps]"). It wants the short form. Normalise here rather than
  # discovering it as an empty table at the worst moment.
  workloads="$(kubectl --context="$c" -n "$APP_NS" get deploy -o name 2>/dev/null \
    | sed 's|^deployment\.apps/|deploy/|')"
  [ -n "$workloads" ] || { printf '  (no workloads)\n'; return; }

  local min_remain=""
  for w in $workloads; do
    # No `exit` in the awk program. Exiting early closes the pipe while the
    # linkerd CLI is still writing, which kills it with SIGPIPE; combined with
    # `pipefail` that makes the whole pipeline return 141 and `set -e` aborts
    # the script. The symptom is an empty report with no error message.
    # Read the whole stream and keep the first match instead.
    exp="$(linkerd --context="$c" diagnostics proxy-metrics -n "$APP_NS" "$w" 2>/dev/null \
      | awk '/^control_identity_cert_expiration_timestamp_seconds/ && !seen { v=$2; seen=1 }
             END { if (seen) print v }' \
      | sed 's/\..*//')"

    if [ -z "$exp" ]; then
      printf '%-28s %-12s %s\n' "${w#deploy/}" '?' 'no metric'
      continue
    fi

    remain=$(( exp - NOW ))
    if [ -z "$min_remain" ] || [ "$remain" -lt "$min_remain" ]; then min_remain="$remain"; fi

    local human color
    human="$(printf '%dh%02dm' $((remain / 3600)) $(((remain % 3600) / 60)))"
    # `[ cond ] && assign` evaluates to 1 when the condition is false, and under
    # `set -e` that exits the script. With healthy certificates (remain well
    # above both thresholds) this silently aborted the report right after the
    # header, which looked like "no workloads found" rather than a shell bug.
    # Use if/elif so a false condition is not the statement's exit status.
    if   [ "$remain" -lt 3600 ];  then color='\033[1;31m'   # under 1h
    elif [ "$remain" -lt 21600 ]; then color='\033[1;33m'   # under 6h
    else color='\033[1;32m'
    fi

    printf "%-28s ${color}%-12s\033[0m %s\n" \
      "${w#deploy/}" "$human" "$(date -r "$exp" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$exp" '+%Y-%m-%d %H:%M')"
  done

  if [ -n "$min_remain" ]; then
    printf '\n  minimum headroom in this cluster: %dh%02dm\n' \
      $((min_remain / 3600)) $(((min_remain % 3600) / 60))
    printf '  -> with linkerd-identity down, that is how long this cluster can\n'
    printf '     serve before proxies start losing their identity.\n'
  fi
}

# The trust anchor itself: the one certificate with no failover target.
printf '\033[1mTrust anchor\033[0m\n'
for name in $(clusters); do
  bundle="$(kubectl --context="$(ctx "$name")" -n linkerd get cm linkerd-identity-trust-roots \
    -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null)"
  if [ -z "$bundle" ]; then
    printf '  %-10s (unreachable)\n' "$name"
    continue
  fi
  end="$(echo "$bundle" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  fp="$(echo "$bundle" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | cut -c1-17)"
  printf '  %-10s expires %s   fp %s...\n' "$name" "$end" "$fp"
done

if [ "$TARGET" = "all" ]; then
  for name in $(clusters); do report_cluster "$name"; done
else
  report_cluster "$TARGET"
fi
