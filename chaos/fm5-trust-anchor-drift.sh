#!/usr/bin/env bash
# FM5 -- trust anchor drift.
#
#   chaos/fm5-trust-anchor-drift.sh drift   [cluster]
#   chaos/fm5-trust-anchor-drift.sh idle    [cluster]
#   chaos/fm5-trust-anchor-drift.sh restore [cluster]
#
# WHY THIS IS THE FIFTH FAILURE MODE
#
# Every other fault in this repo is bounded -- a zone, a cluster, a region --
# and a bounded failure domain has somewhere to fail over to. The trust anchor
# is the one piece of state every cluster in every region validates against, so
# it is the only failure domain with NO failover target. "Run it in the other
# region" is not an answer when the other region validates against the same
# certificate.
#
# WHAT `drift` DOES, AND WHY IT IS THE REALISTIC SHAPE
#
# It re-issues ONE cluster's issuer from a DIFFERENT root, then restarts that
# cluster's identity controller so it starts minting leaf certificates nothing
# else trusts. That is a coordinated rotation that went wrong in one cluster --
# far more likely than a simultaneous global expiry, and the failure Buoyant's
# own docs say the 2.20 rotation operator does not yet cover for multicluster:
#
#   "The current implementation targets single-cluster setups. Multicluster
#    trust rotation is not yet available."
#
# Existing proxies keep working: they already hold valid leaves and the mesh
# does not re-validate on every request. The damage lands on pods that restart
# and on connections that re-establish, which is exactly what a DR event causes.
#
# WHAT `idle` IS FOR
#
# results/FINDINGS.md records that at rest HAZL uses one same-zone endpoint per
# cluster -- three of nine -- and that the OTHER six carry no traffic until
# stress makes HAZL expand into them. That is the repo's sharpest untested
# claim: a trust fault confined to idle replicas is invisible until an incident
# reaches for them.
#
# The anchor is per-CLUSTER state and cannot be broken for a single pod, so the
# only way to construct it is to make a whole cluster idle first. `idle` removes
# the target's same-zone replica so HAZL stops using it, which turns the drift
# from an immediate failure into a latent one. FM5b then applies FM3's brownout
# to force expansion into the drifted cluster and shows the failure appearing
# only under stress.
#
# RESTORE
#
# This rewrites certificates on disk, so the original root and issuer are copied
# aside BEFORE anything is overwritten -- the same lesson as FM1's restore,
# which used to put back one replica of three because it never recorded what it
# found. Restore puts the originals back and re-runs the control plane install
# for the affected cluster.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl step

ACTION="${1:-}"
# east by default: west hosts the observability stack, and central is FM1's
# target. See the topology note in clusters/lib.sh.
TARGET="${2:-east}"
CTX="$(ctx "$TARGET")"

CERT_DIR="${REPO_ROOT}/certs"
BACKUP_DIR="${REPO_ROOT}/viz/data/fm5-${TARGET}"
DRIFT_VALIDITY="${DRIFT_VALIDITY:-2160h}"

# Everything this fault overwrites, recorded before it is touched.
save_originals() {
  mkdir -p "$BACKUP_DIR"
  local f
  for f in "issuer-${TARGET}.crt" "issuer-${TARGET}.key"; do
    if [ ! -f "${BACKUP_DIR}/${f}" ]; then
      cp "${CERT_DIR}/${f}" "${BACKUP_DIR}/${f}"
      log "  saved original ${f}"
    fi
  done
}

restore_originals() {
  local f restored=0
  for f in "issuer-${TARGET}.crt" "issuer-${TARGET}.key"; do
    if [ -f "${BACKUP_DIR}/${f}" ]; then
      cp "${BACKUP_DIR}/${f}" "${CERT_DIR}/${f}"
      restored=$((restored + 1))
    fi
  done
  # Refuse quietly-wrong restores. If the backup is missing, re-running the
  # install would push the DRIFTED issuer back out and the rig would look
  # restored while still being broken.
  [ "$restored" -eq 2 ] || die "no saved issuer for '${TARGET}' in ${BACKUP_DIR}.
     Restoring now would re-install the drifted certificate and leave the rig
     broken while reporting success. Regenerate with:
       FORCE_CERTS=1 bash clusters/03-certs.sh && bash clusters/04-linkerd.sh"
  ok "  original issuer restored from ${BACKUP_DIR}"
  rm -rf "$BACKUP_DIR"
}

# Patch the EXISTING secret rather than recreating it.
#
# `kubectl create secret tls` would produce type kubernetes.io/tls with keys
# tls.crt / tls.key. The real secret is Opaque with **crt.pem / key.pem**, which
# is what the identity container mounts -- recreating it would leave a secret
# the control plane cannot read, and the failure would look like the drift
# rather than like a harness bug.
set_issuer() {
  kubectl --context="$CTX" -n linkerd patch secret linkerd-identity-issuer \
    --type=merge -p "{\"data\":{
      \"crt.pem\":\"$(base64 < "${CERT_DIR}/issuer-${TARGET}.crt" | tr -d '\n')\",
      \"key.pem\":\"$(base64 < "${CERT_DIR}/issuer-${TARGET}.key" | tr -d '\n')\"}}" >/dev/null
}

case "$ACTION" in
  drift)
    save_originals

    log "FM5: minting a rogue root and re-issuing '${TARGET}' from it"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    step certificate create rogue.linkerd.cluster.local \
      "${tmp}/rogue.crt" "${tmp}/rogue.key" \
      --profile root-ca --not-after 8760h --no-password --insecure >/dev/null
    step certificate create identity.linkerd.cluster.local \
      "${CERT_DIR}/issuer-${TARGET}.crt" "${CERT_DIR}/issuer-${TARGET}.key" \
      --profile intermediate-ca \
      --not-after "$DRIFT_VALIDITY" \
      --ca "${tmp}/rogue.crt" --ca-key "${tmp}/rogue.key" \
      --no-password --insecure --force >/dev/null
    ok "  '${TARGET}' issuer now chains to a root no other cluster trusts"

    # Push it into the cluster and restart identity so it mints from the new
    # issuer. The trust anchor bundle is left alone deliberately: this models a
    # rotation where the ISSUER was replaced and the anchor was not distributed,
    # which is the half that actually goes wrong.
    log "  installing the drifted issuer into '${TARGET}'"
    set_issuer
    kubectl --context="$CTX" -n linkerd rollout restart deploy/linkerd-identity >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n linkerd rollout status deploy/linkerd-identity --timeout=180s >/dev/null 2>&1 || true
    ok "  identity restarted in '${TARGET}'"

    cat <<EOF

'${TARGET}' now mints leaf certificates from a root no other cluster trusts.

Existing proxies are UNAFFECTED -- they hold valid leaves already, and the mesh
does not re-validate established peers on every request. The damage lands on
pods that restart and on connections that re-establish, which is precisely what
a DR event causes.

  verify/fm5-verify.sh drift
  linkerd --context=${CTX} check --proxy

Restore with: chaos/fm5-trust-anchor-drift.sh restore ${TARGET}
EOF
    ;;

  anchor)
    # A rotation that COMPLETED in one cluster and reached no other.
    #
    # `drift` alone does not work, and finding out why was the more useful
    # result: linkerd-identity validates a new issuer against the trust anchors
    # BEFORE adopting it, and refuses one that does not chain --
    #
    #   "Skipping issuer update as certs could not be read from disk: failed to
    #    verify issuer credentials ... x509: certificate signed by unknown
    #    authority"
    #
    # -- then keeps serving on the PREVIOUS issuer. Linkerd fails safe on issuer
    # drift alone.
    #
    # So the fault has to rotate BOTH halves in the target: a rogue root as its
    # trust anchor AND an issuer minted from that root. The cluster is then
    # internally consistent and externally incompatible, which is exactly the
    # shape of a multicluster rotation that succeeded locally and was never
    # distributed -- the case Buoyant's docs say the 2.20 rotation operator does
    # not yet cover.
    save_originals
    mkdir -p "$BACKUP_DIR"
    if [ ! -f "${BACKUP_DIR}/ca-bundle.crt" ]; then
      kubectl --context="$CTX" -n linkerd get cm linkerd-identity-trust-roots \
        -o jsonpath='{.data.ca-bundle\.crt}' > "${BACKUP_DIR}/ca-bundle.crt"
      log "  saved original trust anchor bundle"
    fi

    log "FM5: rotating '${TARGET}' onto a root no other cluster has"
    rogue="${BACKUP_DIR}/rogue"
    step certificate create rogue-root.linkerd.cluster.local \
      "${rogue}.crt" "${rogue}.key" \
      --profile root-ca --not-after 8760h --no-password --insecure --force >/dev/null
    step certificate create identity.linkerd.cluster.local \
      "${CERT_DIR}/issuer-${TARGET}.crt" "${CERT_DIR}/issuer-${TARGET}.key" \
      --profile intermediate-ca --not-after "$DRIFT_VALIDITY" \
      --ca "${rogue}.crt" --ca-key "${rogue}.key" \
      --no-password --insecure --force >/dev/null

    # Anchor first, then the issuer: the other order makes identity reject the
    # issuer against the old anchor and log a warning instead of rotating.
    kubectl --context="$CTX" -n linkerd create cm linkerd-identity-trust-roots \
      --from-file=ca-bundle.crt="${rogue}.crt" \
      --dry-run=client -o yaml | kubectl --context="$CTX" apply -f - >/dev/null
    set_issuer
    kubectl --context="$CTX" -n linkerd rollout restart deploy/linkerd-identity >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n linkerd rollout status deploy/linkerd-identity --timeout=180s >/dev/null 2>&1 || true
    ok "  '${TARGET}' now trusts only its own rogue root"

    cat <<EOF

'${TARGET}' has completed a rotation nobody else received. It trusts only the
rogue root and mints leaves from it; every other cluster still trusts the
shared anchor. Cross-cluster mTLS with '${TARGET}' should now fail in BOTH
directions, while traffic inside it keeps working.

Proxies read the trust bundle at startup, so restart the workloads to make the
fault land:

  kubectl --context=${CTX} -n ${APP_NS} rollout restart deploy

Restore with: chaos/fm5-trust-anchor-drift.sh restore ${TARGET}
EOF
    ;;

  idle)
    # Make the target invisible to HAZL, so a later drift is LATENT.
    #
    # HAZL keeps one same-zone endpoint per cluster. Remove the target's replica
    # in the load generator's zone and it stops being part of the active set --
    # which is the only way to construct "the fault is on endpoints nothing is
    # using", given the anchor is per-cluster state.
    zone="$(kubectl --context="$(ctx "${LOAD_CLUSTER:-west}")" get node \
      "$(kubectl --context="$(ctx "${LOAD_CLUSTER:-west}")" -n "$APP_NS" \
         get pod -l app=loadgen -o jsonpath='{.items[0].spec.nodeName}')" \
      -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)"
    [ -n "$zone" ] || die "could not determine the load generator's zone"

    log "FM5b: removing '${TARGET}' app pods in ${zone} so HAZL stops using the cluster"
    for node in $(kubectl --context="$CTX" get nodes \
        -l "topology.kubernetes.io/zone=${zone}" -o name 2>/dev/null | sed 's|node/||'); do
      for p in $(kubectl --context="$CTX" -n "$APP_NS" get pods -l app=app \
          --field-selector="spec.nodeName=${node}" -o name 2>/dev/null | sed 's|pod/||'); do
        kubectl --context="$CTX" -n "$APP_NS" delete pod "$p" --grace-period=10 >/dev/null 2>&1 || true
        ok "  removed ${p} (was in ${zone})"
      done
    done
    kubectl --context="$CTX" -n "$APP_NS" patch deploy app --type=merge \
      -p "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"topology.kubernetes.io/zone\",\"operator\":\"NotIn\",\"values\":[\"${zone}\"]}]}]}}}}}}}" >/dev/null
    kubectl --context="$CTX" -n "$APP_NS" rollout status deploy/app --timeout=180s >/dev/null 2>&1 || true
    ok "  '${TARGET}' now has no app pod in ${zone}"
    ;;

  restore)
    log "FM5 restore: putting '${TARGET}' back on the shared trust anchor"

    # Anchor first, for the same ordering reason as the injection: with the
    # rogue anchor still in place identity would reject the restored issuer and
    # log a warning, leaving the cluster broken while this reported success.
    if [ -f "${BACKUP_DIR}/ca-bundle.crt" ]; then
      kubectl --context="$CTX" -n linkerd create cm linkerd-identity-trust-roots \
        --from-file=ca-bundle.crt="${BACKUP_DIR}/ca-bundle.crt" \
        --dry-run=client -o yaml | kubectl --context="$CTX" apply -f - >/dev/null
      ok "  original trust anchor bundle restored"
    fi
    restore_originals

    set_issuer
    kubectl --context="$CTX" -n linkerd rollout restart deploy/linkerd-identity >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n linkerd rollout status deploy/linkerd-identity --timeout=180s >/dev/null 2>&1 || true

    # Undo `idle` if it ran, then restart the workloads so every proxy picks up
    # a leaf from the restored issuer. Without this the cluster is repaired and
    # its pods still hold rogue certificates.
    kubectl --context="$CTX" -n "$APP_NS" patch deploy app --type=json \
      -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]' >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n "$APP_NS" rollout restart deploy >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n "$APP_NS" rollout status deploy --timeout=240s >/dev/null 2>&1 || true
    ok "  workloads restarted onto the restored issuer"

    bash "${REPO_ROOT}/verify/meshed.sh" --fix >/dev/null 2>&1 || true
    ok "  control plane restored in '${TARGET}'"
    ;;

  *)
    die "usage: fm5-trust-anchor-drift.sh <drift|anchor|idle|restore> [cluster]"
    ;;
esac
