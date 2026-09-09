#!/usr/bin/env bash
# Generate the mTLS certificate hierarchy.
#
#   root.crt  (the TRUST ANCHOR)     -- shared by every cluster
#     |
#     +-- issuer-west.crt            -- per-cluster intermediate
#     +-- issuer-east.crt
#     +-- issuer-central.crt
#
# The trust anchor is the whole point of this repo's FM5 experiment: it is the
# only piece of state shared across every cluster and every region, so it is the
# only failure domain with no failover target. Per-cluster issuers are used
# rather than one shared issuer because they are the realistic production shape
# and they let us break exactly one cluster's identity independently.
#
# These are static self-signed certs, which is what Linkerd's quickstart does.
# FM5 swaps this out for cert-manager + trust-manager, which is what you should
# actually run in production -- see chaos/fm5-trust-anchor-drift.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need step

CERT_DIR="${REPO_ROOT}/certs"
mkdir -p "$CERT_DIR"

# Validity of the trust anchor. Deliberately short-ish so that "how much
# certificate headroom do we have?" is a live question in this environment
# rather than an abstraction -- that is one of the metrics the post reports.
ROOT_VALIDITY="${ROOT_VALIDITY:-8760h}"    # 1 year
ISSUER_VALIDITY="${ISSUER_VALIDITY:-2160h}" # 90 days

if [ -f "${CERT_DIR}/root.crt" ] && [ "${FORCE_CERTS:-0}" != "1" ]; then
  log "trust anchor already exists at ${CERT_DIR}/root.crt (FORCE_CERTS=1 to regenerate)"
else
  log "generating shared trust anchor (valid ${ROOT_VALIDITY})"
  rm -f "${CERT_DIR}"/*.crt "${CERT_DIR}"/*.key
  step certificate create root.linkerd.cluster.local \
    "${CERT_DIR}/root.crt" "${CERT_DIR}/root.key" \
    --profile root-ca \
    --not-after "$ROOT_VALIDITY" \
    --no-password --insecure
  ok "trust anchor: ${CERT_DIR}/root.crt"
fi

for name in $(clusters); do
  crt="${CERT_DIR}/issuer-${name}.crt"
  key="${CERT_DIR}/issuer-${name}.key"

  if [ -f "$crt" ] && [ "${FORCE_CERTS:-0}" != "1" ]; then
    log "issuer for '${name}' already exists"
    continue
  fi

  log "generating issuer for '${name}' (valid ${ISSUER_VALIDITY})"
  step certificate create identity.linkerd.cluster.local "$crt" "$key" \
    --profile intermediate-ca \
    --not-after "$ISSUER_VALIDITY" \
    --ca "${CERT_DIR}/root.crt" \
    --ca-key "${CERT_DIR}/root.key" \
    --no-password --insecure
  ok "issuer: ${crt}"
done

log "certificate inventory"
printf '\n%-28s %-12s %s\n' FILE EXPIRES SUBJECT
printf -- '--------------------------------------------------------------------\n'
for f in "${CERT_DIR}"/root.crt "${CERT_DIR}"/issuer-*.crt; do
  [ -f "$f" ] || continue
  expiry="$(step certificate inspect "$f" --format json | jq -r '.validity.end')"
  subject="$(step certificate inspect "$f" --format json | jq -r '.subject.common_name[0]')"
  printf '%-28s %-12s %s\n' "$(basename "$f")" "${expiry%%T*}" "$subject"
done

cat <<EOF

The trust anchor fingerprint below must be identical on every cluster. When it
is not, cross-cluster mTLS fails -- which is exactly what FM5 induces.

  $(step certificate fingerprint "${CERT_DIR}/root.crt")
EOF
