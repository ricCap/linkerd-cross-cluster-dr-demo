#!/usr/bin/env bash
# Gate: prove pod-to-pod reachability across every ordered pair of clusters.
#
# Routes existing in a node's table is not the same as traffic flowing. This
# deploys one throwaway echo pod per cluster, then curls each one's *pod IP*
# from inside every other cluster. Exits non-zero if any pair fails, so it can
# be used as a hard gate before installing Linkerd.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl jq

NS=netcheck
IMAGE_SERVER=ghcr.io/stefanprodan/podinfo:6.9.2
IMAGE_CLIENT=curlimages/curl:8.11.1

cleanup() {
  local name
  for name in $(clusters); do
    kubectl --context="$(ctx "$name")" delete ns "$NS" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

log "deploying echo pod in each cluster (namespace ${NS})"
for name in $(clusters); do
  c="$(ctx "$name")"
  kubectl --context="$c" create ns "$NS" >/dev/null 2>&1 || true
  kubectl --context="$c" -n "$NS" run echo \
    --image="$IMAGE_SERVER" \
    --labels=app=echo \
    --port=9898 \
    --restart=Never >/dev/null 2>&1 || true
done

for name in $(clusters); do
  c="$(ctx "$name")"
  kubectl --context="$c" -n "$NS" wait pod/echo \
    --for=condition=ready --timeout=120s >/dev/null \
    || die "echo pod never became ready in ${name}"
done

# Map cluster -> echo pod IP.
IPS=""
for name in $(clusters); do
  ip="$(kubectl --context="$(ctx "$name")" -n "$NS" get pod echo \
        -o jsonpath='{.status.podIP}')"
  [ -n "$ip" ] || die "no pod IP for echo in ${name}"
  IPS="${IPS}${name}:${ip}
"
  ok "${name} echo pod at ${ip}"
done

printf '\n%-10s %-10s %-16s %s\n' SOURCE TARGET TARGET_POD_IP RESULT
printf -- '---------------------------------------------------------\n'

fails=0
for src in $(clusters); do
  for dst in $(clusters); do
    [ "$src" != "$dst" ] || continue
    dst_ip="$(echo "$IPS" | grep "^${dst}:" | cut -d: -f2)"

    # Retry: pod scheduling and CNI setup race often enough that a single
    # attempt produces false failures, and this script is a hard gate.
    probe() {
      kubectl --context="$(ctx "$src")" -n "$NS" run "probe-$$-${dst}-${1}" \
        --image="$IMAGE_CLIENT" --restart=Never --rm -i --quiet \
        --command -- curl -sS --max-time 8 -o /dev/null \
        -w '%{http_code}' "http://${dst_ip}:9898/healthz" 2>/dev/null \
        | grep -q '^200$'
    }

    if probe 1 || probe 2 || probe 3; then
      printf '%-10s %-10s %-16s \033[1;32mPASS\033[0m\n' "$src" "$dst" "$dst_ip"
    else
      printf '%-10s %-10s %-16s \033[1;31mFAIL\033[0m\n' "$src" "$dst" "$dst_ip"
      fails=$((fails + 1))
    fi
  done
done

echo
if [ "$fails" -ne 0 ]; then
  die "${fails} cluster pair(s) cannot reach each other pod-to-pod.
The flat network is not working. Check:
  - clusters/02-routes.sh ran without warnings
  - pod CIDRs really are distinct (clusters/lib.sh CLUSTER_TABLE)
  - all node containers are on the '${DOCKER_NET}' docker network"
fi

ok "flat network verified: all $(clusters | wc -l | tr -d ' ') clusters reach each other pod-to-pod"
