#!/usr/bin/env bash
# Register the clusters with Buoyant Cloud (the enterprise.buoyant.io dashboard).
#
#   clusters/11-buoyant-agent.sh install
#   clusters/11-buoyant-agent.sh status
#   clusters/11-buoyant-agent.sh uninstall
#
# A BEL install from the Helm charts gets you the enterprise SOFTWARE and
# nothing else: the license authenticates the chart pull, it does not enrol the
# cluster anywhere. Until the Buoyant Cloud agent is installed the clusters are
# invisible at enterprise.buoyant.io, which is surprising precisely because
# everything else about the install says "enterprise".
#
# WHAT THIS MEANS FOR THE EXPERIMENTS, WHICH IS WHY IT IS WORTH HAVING
#
# The FM4 lesson in results/FINDINGS.md is that an in-cluster observability
# stack is inside the blast radius of the thing it observes, and that the
# production answer is to host it outside every cluster it watches. Buoyant
# Cloud IS that -- a genuinely external observer, which the rig otherwise has
# no example of.
#
# It is not a free win, and the contrast is the interesting part:
#
#   FM2-hard and FM4 partition nodes off the Docker network entirely. The agent
#   loses its uplink along with everything else, so the hosted dashboard goes
#   blind for exactly the clusters under test -- while west's in-cluster
#   Grafana, watching from outside the failure domain, keeps reporting.
#
#   So neither placement dominates. External survives the cluster dying;
#   in-cluster survives the network dying. A DR plan that has only one of them
#   has an unexamined assumption about which failure it expects.
#
# Report both in the write-up rather than picking a winner.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl

ACTION="${1:-install}"

# Cluster names in Buoyant Cloud are global to the org, and this rig's names --
# west, east, central -- are exactly the names somebody's real clusters have.
# Prefix them so a demo rig cannot collide with, or be mistaken for, production.
PREFIX="${BUOYANT_CLUSTER_PREFIX:-dr}"

# The agent CLI ships alongside the enterprise linkerd binary.
AGENT_CLI="${AGENT_CLI:-$HOME/.linkerd2-bel/bin/linkerd-buoyant}"

creds_present() {
  [ -n "${BUOYANT_CLOUD_CLIENT_ID:-}" ] && [ -n "${BUOYANT_CLOUD_CLIENT_SECRET:-}" ]
}

# Skip loudly or not at all.
#
# clusters/lib.sh once documented ENFORCE_MESH while nothing referenced it, so
# `ENFORCE_MESH=1 task up` silently did nothing and every result taken under it
# was unreproducible from the documented interface. A build step that quietly
# does nothing is the same bug. If this cannot run, it says so in terms that
# name the fix.
require_creds_or_explain() {
  creds_present && return 0
  cat >&2 <<EOF

$(warn "Buoyant Cloud agent NOT installed -- the clusters will not appear at
     enterprise.buoyant.io. Everything else about this run is unaffected.")

     The BEL license authenticates the Helm charts. Enrolling a cluster in the
     dashboard is a separate credential:

       1. open https://buoyant.cloud/settings?cli=1
       2. append to ${REPO_ROOT}/settings.local.sh (gitignored):

            export BUOYANT_CLOUD_CLIENT_ID="<id>"
            export BUOYANT_CLOUD_CLIENT_SECRET="<secret>"

       3. bash clusters/11-buoyant-agent.sh install

EOF
  return 1
}

case "$ACTION" in
  install)
    if [ "${LINKERD_FLAVOR:-oss}" != "bel" ] && [ "${BUOYANT_AGENT:-}" != "1" ]; then
      log "flavor is '${LINKERD_FLAVOR:-oss}', skipping the Buoyant Cloud agent"
      log "  (BUOYANT_AGENT=1 installs it anyway -- Buoyant Cloud supports OSS too)"
      exit 0
    fi

    if ! require_creds_or_explain; then
      # Explicitly asked for -> a missing credential is an error. Merely implied
      # by the flavor -> a warning, so `task up` still completes for anyone
      # running BEL without a Buoyant Cloud account.
      [ "${BUOYANT_AGENT:-}" = "1" ] && die "BUOYANT_AGENT=1 but no Buoyant Cloud credentials"
      exit 0
    fi

    [ -x "$AGENT_CLI" ] || die "linkerd-buoyant CLI not found at ${AGENT_CLI}.
Install it with:  curl -sL https://enterprise.buoyant.io/install | sh"

    export BUOYANT_CLOUD_CLIENT_ID BUOYANT_CLOUD_CLIENT_SECRET

    for name in $(clusters); do
      c="$(ctx "$name")"
      bc_name="${PREFIX}-${name}"
      log "cluster '${name}' -> Buoyant Cloud as '${bc_name}'"

      # With an agent already present the CLI returns an UPDATED manifest for it
      # and --cluster-name is not accepted; without one it registers under the
      # given name. Branch on what is actually there rather than assuming a
      # clean cluster, so re-running `task up` reconciles instead of failing.
      if kubectl --context="$c" get ns buoyant-cloud >/dev/null 2>&1; then
        log "  agent already present -- refreshing its manifest"
        "$AGENT_CLI" --context="$c" install
      else
        "$AGENT_CLI" --context="$c" install --cluster-name="$bc_name"
      fi | kubectl --context="$c" apply -f - >/dev/null

      ok "  agent applied"
    done

    log "waiting for agents to become ready"
    for name in $(clusters); do
      kubectl --context="$(ctx "$name")" -n buoyant-cloud \
        rollout status deploy --timeout=120s >/dev/null 2>&1 \
        || warn "  '${name}': agent deployments are slow"
    done

    ok "clusters registered -- https://enterprise.buoyant.io"
    ;;

  status)
    for name in $(clusters); do
      c="$(ctx "$name")"
      printf '  %-10s ' "$name"
      if kubectl --context="$c" get ns buoyant-cloud >/dev/null 2>&1; then
        kubectl --context="$c" -n buoyant-cloud get deploy --no-headers 2>/dev/null \
          | awk '{printf "%s=%s ", $1, $2}'
        echo
      else
        echo "no agent"
      fi
    done
    ;;

  uninstall)
    [ -x "$AGENT_CLI" ] || die "linkerd-buoyant CLI not found at ${AGENT_CLI}"
    for name in $(clusters); do
      c="$(ctx "$name")"
      log "removing agent from '${name}'"
      "$AGENT_CLI" --context="$c" uninstall | kubectl --context="$c" delete -f - >/dev/null 2>&1 || true
      ok "  removed"
    done
    ;;

  *)
    die "usage: 11-buoyant-agent.sh <install|status|uninstall>"
    ;;
esac
