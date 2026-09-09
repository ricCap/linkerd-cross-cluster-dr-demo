#!/usr/bin/env bash
# Turn mesh membership from a request into a requirement.
#
#   clusters/10-enforce-mesh.sh on
#   clusters/10-enforce-mesh.sh off
#   clusters/10-enforce-mesh.sh status
#
# THE PROBLEM THIS SOLVES
#
# Three separate times in this exercise, a cluster recovered and brought its
# workloads back WITHOUT proxies -- Running, Ready, passing health checks,
# serving cross-cluster traffic in plaintext, with authorization policy silently
# unenforced. Nothing rejected them and nothing alerted.
#
# That is not a bug. It is two defaults working as designed:
#
#   1. The proxy injector is a mutating admission webhook with
#      failurePolicy: Ignore. While the injector is unavailable -- precisely
#      when a cluster is restarting -- pods are admitted without a proxy.
#      Admission does not retry, so they stay that way until something restarts
#      them.
#
#   2. defaultInboundPolicy is all-unauthenticated, so meshed pods accept
#      connections from unmeshed plaintext clients rather than refusing them.
#
# Individually each is a sensible adoption default. Together they mean a control
# plane blip silently degrades your security posture and nothing tells you.
#
# THE TRADE-OFF, STATED PLAINLY
#
# failurePolicy=Fail means pods cannot be created while the injector is down.
# You are trading a silent security failure for a loud availability failure.
# For most people running a mesh for mTLS that is the right trade -- but it is a
# choice, and turning it on changes what a control plane outage looks like.
# FM1 exercises exactly that interaction.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl

ACTION="${1:-status}"
WEBHOOK=linkerd-proxy-injector-webhook-config

show_status() {
  printf '\n%-10s %-16s %-24s\n' CLUSTER FAILURE_POLICY DEFAULT_INBOUND_POLICY
  printf -- '--------------------------------------------------------\n'
  local name c fp dip
  for name in $(clusters); do
    c="$(ctx "$name")"
    fp="$(kubectl --context="$c" get mutatingwebhookconfiguration "$WEBHOOK" \
      -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null || echo '?')"
    # Read the NAMESPACE annotation, not the cluster-wide default: we scope the
    # policy to the app namespace, so the cluster default stays
    # all-unauthenticated and reading it would always show the change as absent.
    dip="$(kubectl --context="$c" get ns "$APP_NS" \
      -o jsonpath='{.metadata.annotations.config\.linkerd\.io/default-inbound-policy}' 2>/dev/null)"
    [ -n "$dip" ] || dip="$(kubectl --context="$c" -n linkerd get cm linkerd-config -o yaml 2>/dev/null \
      | sed -n 's/.*defaultInboundPolicy: *//p' | head -1)(cluster default)"
    printf '%-10s %-16s %-24s\n' "$name" "${fp:-?}" "${dip:-?}"
  done
  cat <<'EOF'

  failurePolicy=Ignore          pods admitted unmeshed when the injector is down
  failurePolicy=Fail            pod creation rejected instead -- no silent gaps

  all-unauthenticated           meshed pods accept plaintext from unmeshed peers
  all-authenticated             plaintext refused, so the failure is loud
EOF
}

case "$ACTION" in
  on)
    log "enforcing mesh membership on all clusters"
    for name in $(clusters); do
      c="$(ctx "$name")"

      kubectl --context="$c" patch mutatingwebhookconfiguration "$WEBHOOK" \
        --type=json -p '[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]' >/dev/null \
        && ok "  ${name}: injector failurePolicy=Fail"

      # Namespace-scoped rather than cluster-wide: turning the whole cluster to
      # all-authenticated would break kubelet probes and any unmeshed system
      # component, which is a much bigger change than this experiment needs.
      kubectl --context="$c" annotate ns "$APP_NS" \
        config.linkerd.io/default-inbound-policy=all-authenticated --overwrite >/dev/null \
        && ok "  ${name}: ${APP_NS} default-inbound-policy=all-authenticated"
    done

    warn "pods can no longer be created while the proxy injector is unavailable"

    # Restart, rather than print an instruction to restart.
    #
    # The inbound-policy annotation is read by the proxy at startup, so pods that
    # were already running keep the OLD policy. Leaving that as a manual step
    # meant the common case -- enforce, then run an experiment -- measured an
    # "enforced" cluster where every workload was still accepting plaintext.
    # That is a config that exists in neither arm of the comparison.
    for name in $(clusters); do
      c="$(ctx "$name")"
      if kubectl --context="$c" -n "$APP_NS" get deploy -o name >/dev/null 2>&1; then
        kubectl --context="$c" -n "$APP_NS" rollout restart deploy >/dev/null 2>&1 || true
        kubectl --context="$c" -n "$APP_NS" rollout status deploy --timeout=120s >/dev/null 2>&1 \
          && ok "  ${name}: workloads restarted under the new policy" \
          || warn "  ${name}: workloads slow to restart -- check before measuring"
      fi
    done

    show_status
    ;;

  off)
    log "reverting to Linkerd defaults"
    for name in $(clusters); do
      c="$(ctx "$name")"
      kubectl --context="$c" patch mutatingwebhookconfiguration "$WEBHOOK" \
        --type=json -p '[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' >/dev/null \
        && ok "  ${name}: injector failurePolicy=Ignore"
      kubectl --context="$c" annotate ns "$APP_NS" \
        config.linkerd.io/default-inbound-policy- >/dev/null 2>&1 \
        && ok "  ${name}: ${APP_NS} inbound policy annotation removed" || true
    done
    show_status
    ;;

  status) show_status ;;
  *) die "usage: 10-enforce-mesh.sh <on|off|status>" ;;
esac
