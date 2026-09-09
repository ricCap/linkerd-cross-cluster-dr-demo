#!/usr/bin/env bash
# Gate: is everything that should be in the mesh actually in the mesh?
#
#   verify/meshed.sh          report, exit non-zero if anything is unmeshed
#   verify/meshed.sh --fix    restart the affected deployments to re-inject
#
# WHY THIS EXISTS
#
# Proxy injection happens once, at pod admission, via a mutating webhook served
# by the linkerd control plane. If a pod is created while that webhook is
# unavailable -- which is exactly what happens when a cluster restarts, because
# workloads race the control plane on the way up -- the pod is admitted WITHOUT
# a proxy.
#
# Nothing complains. The pod is Running. It is Ready. It passes its health
# checks and serves traffic. But it is outside the mesh: no mTLS, no
# authorization policy, no proxy metrics. A recovered cluster can sit there
# looking perfectly healthy while quietly serving plaintext.
#
# Observed here after a cluster recovery: all nine of east's workload pods came
# back unmeshed, and cross-cluster traffic to them silently changed from
# tls="true" to tls="no_identity". The dashboards showed green. The only signal
# was the container count going from 2/2 to 1/1.
#
# This is the single best argument for why the mesh tier needs its own DR
# verification: "the cluster is back" and "the mesh is back" are different
# claims, and only one of them is on your dashboard.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

# Namespaces that must be fully meshed.
MESHED_NS="${MESHED_NS:-${APP_NS} linkerd-multicluster linkerd-viz}"

total_unmeshed=0

for name in $(clusters); do
  c="$(ctx "$name")"
  printf '\n\033[1m--- %s ---\033[0m\n' "$name"

  if ! kubectl --context="$c" cluster-info >/dev/null 2>&1; then
    warn "  unreachable, skipping"
    continue
  fi

  cluster_unmeshed=0
  for ns in $MESHED_NS; do
    kubectl --context="$c" get ns "$ns" >/dev/null 2>&1 || continue

    # A meshed pod has the linkerd-proxy container. Checking for the container
    # by name is more precise than counting ready containers, which varies by
    # workload.
    # The proxy may be a regular container OR a native sidecar init container,
    # depending on the Kubernetes version: from 1.29 onward Linkerd injects it
    # into initContainers with restartPolicy: Always. On k3s v1.33 (what this
    # repo pins) it is ALWAYS an init container, so checking only .spec.containers
    # reports every healthy pod as unmeshed. Check both lists.
    #
    # Pods on their way out are excluded: they are not serving new traffic.
    unmeshed="$(kubectl --context="$c" -n "$ns" get pods \
      --field-selector=status.phase=Running -o json 2>/dev/null \
      | jq -r '
          .items[]
          | select(.metadata.deletionTimestamp == null)
          | select(
              ([(.spec.containers // [])[].name] + [(.spec.initContainers // [])[].name])
              | index("linkerd-proxy") | not
            )
          | .metadata.name + "\t" + ((.metadata.ownerReferences // [{}])[0].name // "?")
        ' 2>/dev/null)"

    if [ -n "$unmeshed" ]; then
      n="$(echo "$unmeshed" | grep -c .)"
      cluster_unmeshed=$((cluster_unmeshed + n))
      printf '  \033[1;31m%s unmeshed pod(s) in %s\033[0m\n' "$n" "$ns"
      echo "$unmeshed" | awk -F'\t' '{printf "      %-40s (owner: %s)\n", $1, $2}'

      if [ "$FIX" = "1" ]; then
        # Retry, because the remedy reproduces the fault.
        #
        # Restarting a deployment to re-inject creates a fresh set of pods that
        # race the injector all over again, and under failurePolicy=Ignore there
        # is no retry -- so one pass is a roll of the same dice, not a fix.
        # SHORTCOMINGS records a pass that "found 3 unmeshed pods and left 4",
        # and the runs on 2026-09-08 left an unmeshed pod behind that then
        # contaminated the NEXT experiment's mTLS baseline with 469 plaintext
        # requests.
        #
        # Bounded at 3 attempts: this cannot converge under `Ignore` if the
        # injector is genuinely down, and looping forever would hang a restore
        # from inside an EXIT trap -- the same shape as the chaos cleanup that
        # wedged for thirty minutes.
        attempt=1
        while [ "$attempt" -le 3 ]; do
          log "    restarting deployments in ${ns} to re-inject (attempt ${attempt}/3)"
          kubectl --context="$c" -n "$ns" rollout restart deploy >/dev/null 2>&1 || true
          kubectl --context="$c" -n "$ns" rollout status deploy --timeout=240s >/dev/null 2>&1 || true
          still="$(kubectl --context="$c" -n "$ns" get pods -o json 2>/dev/null \
            | jq -r '.items[]
                     | select(.status.phase == "Running")
                     | select(
                         ([(.spec.containers // [])[].name] + [(.spec.initContainers // [])[].name])
                         | index("linkerd-proxy") | not
                       )
                     | .metadata.name' 2>/dev/null | grep -c . || true)"
          if [ "${still:-0}" -eq 0 ]; then
            ok "    ${ns} fully remeshed after ${attempt} attempt(s)"
            break
          fi
          warn "    ${still} pod(s) STILL unmeshed after attempt ${attempt} -- the restart raced the injector again"
          attempt=$((attempt + 1))
        done
        if [ "${still:-0}" -ne 0 ]; then
          warn "    ${ns}: gave up with ${still} unmeshed pod(s).
     Under failurePolicy=Ignore a restart cannot guarantee injection.
     PROFILE=production is the actual fix; until then do not measure mTLS here."
        fi
      fi
    fi
  done

  [ "$cluster_unmeshed" -eq 0 ] && ok "  all pods meshed"
  total_unmeshed=$((total_unmeshed + cluster_unmeshed))
done

echo
if [ "$total_unmeshed" -ne 0 ]; then
  if [ "$FIX" = "1" ]; then
    warn "restarted workloads in response to ${total_unmeshed} unmeshed pod(s) -- re-run to confirm"
    exit 0
  fi
  die "${total_unmeshed} pod(s) are running OUTSIDE the mesh.
They are Running and Ready, and they are serving traffic without mTLS.
Re-run with --fix to restart the affected deployments."
fi

ok "every pod in [${MESHED_NS}] is meshed across all clusters"
