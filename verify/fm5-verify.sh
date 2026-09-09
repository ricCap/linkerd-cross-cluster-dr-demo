#!/usr/bin/env bash
# FM5 -- trust anchor drift. Runs the cycle and exits non-zero on a failed check.
#
#   verify/fm5-verify.sh drift    one cluster's issuer chains to a rogue root
#   verify/fm5-verify.sh latent   the same drift, on a cluster HAZL is not using
#
# WHAT THIS MEASURES THAT THE OTHER FOUR DO NOT
#
# Every other failure mode here is bounded and has somewhere to fail over to.
# The trust anchor does not: it is the one piece of state every cluster in every
# region validates against.
#
# The contrast with the unmeshed-pod finding is the point. Both are identity
# failures and they have OPPOSITE signatures:
#
#   unmeshed pod    no proxy at all  -> traffic succeeds, silently in PLAINTEXT
#   drifted anchor  wrong root       -> traffic FAILS loudly, still encrypted
#
# One is a security failure that looks healthy. The other is an availability
# failure that is impossible to miss. Knowing which one you are looking at
# decides the runbook.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl linkerd

MODE="${1:-drift}"
case "$MODE" in drift|anchor|latent) ;; *) die "usage: fm5-verify.sh <drift|anchor|latent>";; esac

# Which half of a rotation goes wrong decides whether anything happens at all.
#
#   drift    issuer only. Linkerd REJECTS it -- identity validates a new issuer
#            against the trust anchors before adopting it and keeps serving on
#            the old one. Measured 2026-09-08; the cluster carried 4227 requests
#            through the whole window. This arm exists to demonstrate the
#            fail-safe, not a failure.
#   anchor   anchor AND issuer. The cluster is internally consistent and
#            externally incompatible -- a rotation that completed locally and
#            reached nobody else.
#   latent   `anchor`, on a cluster HAZL is not using.
INJECT="$MODE"
# `if`, not `[ ] &&`, to match the convention the rest of this repo enforces.
if [ "$MODE" = "latent" ]; then INJECT="anchor"; fi

TARGET="${TARGET:-east}"
OBSERVER="${OBSERVER:-west}"
CTX="$(ctx "$TARGET")"
SETTLE="${SETTLE:-90}"
RPS="${RPS:-30}"

# Namespaced by PROFILE, like every other runner.
RESULTS="${REPO_ROOT}/results/${PROFILE:-default}/fm5-${MODE}"
mkdir -p "$RESULTS"
echo "$OBSERVER" > "${RESULTS}/observer"
echo "${LINKERD_FLAVOR:-oss}" > "${RESULTS}/flavor"
echo "${PROFILE:-default}" > "${RESULTS}/profile"

MODES="$(modes_for "$OBSERVER")"
mode_svc() { echo "$MODES" | awk -v m="$1" '$1 == m { print $2 }'; }
FED_SVC="$(mode_svc federated)"
FLAT_SVC="$(mode_svc flat)"
GW_SVC="$(mode_svc gateway)"

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

fails=0
check() {
  if [ "$2" = "pass" ]; then printf '%-52s \033[1;32mPASS\033[0m  %s\n' "$1" "$3"
  else printf '%-52s \033[1;31mFAIL\033[0m  %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

snapshot() {
  local label="$1" metrics mode svc t
  eval "t_${label}=\"$(now)\""
  metrics="$(proxy_responses "$OBSERVER")"
  echo "$metrics" > "${RESULTS}/${label}.metrics"
  record_node_state "${RESULTS}/${label}.nodes"
  printf '\n[%s]\n' "$label"
  echo "$MODES" | while read -r mode svc; do
    [ -n "$svc" ] || continue
    t="$(mode_totals "$metrics" "$svc")"
    # shellcheck disable=SC2086
    printf '  %-10s %-22s total=%-8s errors=%-8s non-mTLS=%s\n' "$mode" "$svc" $t
  done
}

cleanup() {
  banner "restoring"
  sampler_stop
  bash "${REPO_ROOT}/chaos/fm5-trust-anchor-drift.sh" restore "$TARGET" 2>&1 \
    | grep -E '  ok|warn' || true
  bash "${REPO_ROOT}/verify/annotate.sh" point "FM5 ${MODE}: restored" "fm5" "restore" >/dev/null 2>&1 || true
  mark_phase restored
}
trap cleanup EXIT

banner "FM5 ${MODE} -- drifting '${TARGET}' off the shared trust anchor, observed from '${OBSERVER}'"

require_control_run
require_settled $(clusters)
require_meshed $(clusters)
require_baseline_view "$OBSERVER" "$FED_SVC" "$(federated_pool_size)"
base_active="$(active_endpoints "$OBSERVER" "$FED_SVC")"
printf '  HAZL is using %s of %s endpoints at rest\n' "$base_active" "$(federated_pool_size)"

mark_phase baseline
sampler_start
snapshot baseline

# `latent` makes the target idle FIRST, so the drift lands on endpoints nothing
# is using. That is the construction the repo's untested claim needs.
if [ "$MODE" = "latent" ]; then
  banner "making '${TARGET}' idle so the drift is latent"
  bash "${REPO_ROOT}/chaos/fm5-trust-anchor-drift.sh" idle "$TARGET" 2>&1 | grep -E '  ok' || true
  sleep 20
  idle_active="$(active_endpoints "$OBSERVER" "$FED_SVC")"
  printf '  HAZL now using %s endpoints (was %s)\n' "$idle_active" "$base_active"
fi

banner "injecting"
annot_start="$(bash "${REPO_ROOT}/verify/annotate.sh" start 2>/dev/null || true)"
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM5 ${MODE}: ${TARGET} off the trust anchor" "fm5" "inject" >/dev/null 2>&1 || true
mark_phase injected

bash "${REPO_ROOT}/chaos/fm5-trust-anchor-drift.sh" "$INJECT" "$TARGET" 2>&1 | grep -E '  ok' || true

# Drift alone changes nothing: existing proxies hold valid leaves and the mesh
# does not re-validate established peers. The fault only lands when a pod
# restarts and asks the drifted issuer for a certificate -- which is what a DR
# event causes, and which has to be triggered deliberately here.
banner "restarting '${TARGET}' workloads so they mint from the drifted issuer"
kubectl --context="$CTX" -n "$APP_NS" rollout restart deploy/app >/dev/null 2>&1 || true
kubectl --context="$CTX" -n "$APP_NS" rollout status deploy/app --timeout=180s >/dev/null 2>&1 || true

log "holding ${SETTLE}s to accumulate traffic against the drifted cluster"
sleep "$SETTLE"
snapshot during

banner "results"

elapsed=$(( t_during - t_baseline ))
expected=$(( RPS * elapsed ))
pct() { [ "$2" -eq 0 ] && echo 0 || echo $(( $1 * 100 / $2 )); }

fed_tp="$(mode_totals_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" | awk '{print $1}')"
fed_err="$(mode_totals_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" | awk '{print $2}')"
fed_tls="$(nontls_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC")"
flat_tp="$(mode_totals_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC" | awk '{print $1}')"
gw_tp="$(mode_totals_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC" | awk '{print $1}')"

printf '\nthroughput over %ss (expected ~%s per mode):\n' "$elapsed" "$expected"
printf '  %-22s %6s reqs (%3s%%)  %6s errors   federated\n' "$FED_SVC"  "$fed_tp"  "$(pct "$fed_tp" "$expected")"  "$fed_err"
printf '  %-22s %6s reqs (%3s%%)                flat mirror\n' "$FLAT_SVC" "$flat_tp" "$(pct "$flat_tp" "$expected")"
printf '  %-22s %6s reqs (%3s%%)                gateway mirror\n' "$GW_SVC"  "$gw_tp"  "$(pct "$gw_tp" "$expected")"

printf '\nfederated traffic by destination cluster (delta from baseline):\n'
distribution_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" | sed 's/^/  /'

printf '\n%-52s %s\n' CHECK RESULT
printf -- '-------------------------------------------------------------------\n'

# 1. The drifted cluster must stop serving the observer. Whether that is loud or
#    silent is check 2 -- this only establishes the fault landed.
served_target="$(distribution_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" \
  | awk -v t="$TARGET" '$1 == t {print $2}')"
served_target="${served_target:-0}"
if [ "$MODE" = "drift" ]; then
  # The fail-safe arm: identity refuses an issuer that does not chain to the
  # trust anchors, so the cluster should keep serving on the previous one. A
  # cluster that DID go down here would mean the validation was bypassed.
  if [ "$served_target" -gt "$(( expected / 20 ))" ]; then
    check "issuer-only drift is REFUSED and the cluster keeps serving" pass \
      "${served_target} reqs from '${TARGET}' -- identity kept the old issuer"
    printf '\n  linkerd-identity validates a new issuer against the trust anchors\n'
    printf '  before adopting it, and on failure keeps the previous one:\n'
    printf '    "Skipping issuer update ... x509: certificate signed by unknown authority"\n'
    printf '  It neither adopts the bad certificate nor crashes. The cost is that\n'
    printf '  a botched rotation is SILENT -- one warning log line, no metric, and\n'
    printf '  a clock running until the old issuer expires.\n'
  else
    check "issuer-only drift is REFUSED and the cluster keeps serving" fail \
      "${served_target} reqs -- the cluster went down, so the issuer was adopted"
  fi
else
  if [ "$served_target" -lt "$(( expected / 20 ))" ]; then
    check "traffic to the drifted cluster stops" pass "${served_target} reqs from '${TARGET}'"
  else
    check "traffic to the drifted cluster stops" fail "${served_target} reqs still served by '${TARGET}'"
  fi
fi

# 2. THE CONTRAST WITH THE UNMESHED FINDING.
#
#    An unmeshed pod keeps serving, in plaintext, with a clean error rate -- a
#    security failure that looks healthy. A drifted anchor must be the opposite:
#    the handshake fails, so traffic STOPS rather than degrading to plaintext.
#    If non-mTLS traffic appeared here instead, the mesh fell back to plaintext
#    on a trust failure, which would be a far more serious finding than the one
#    this experiment expects.
if [ "$fed_tls" -eq 0 ]; then
  check "trust failure does NOT degrade to plaintext" pass "0 non-mTLS -- it fails closed"
else
  check "trust failure does NOT degrade to plaintext" fail "${fed_tls} non-mTLS -- it fell back to plaintext"
fi

# 3. Federation should absorb it: six endpoints still chain to the real root.
if [ "$(pct "$fed_tp" "$expected")" -ge 80 ]; then
  check "federation holds throughput" pass "$(pct "$fed_tp" "$expected")% of expected"
else
  check "federation holds throughput" fail "only $(pct "$fed_tp" "$expected")%"
fi

# 4. Blast radius. The anchor is the one domain with no failover target, so the
#    question that matters is whether a drift in ONE cluster stays there.
other_ok=1
for c in $(clusters); do
  [ "$c" != "$TARGET" ] || continue
  n="$(distribution_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" \
    | awk -v k="$c" '$1 == k {print $2}')"
  [ "${n:-0}" -gt 0 ] || other_ok=0
done
if [ "$MODE" = "drift" ]; then
  : # nothing broke, so "the damage stayed local" is vacuous here
elif [ "$other_ok" = "1" ]; then
  check "blast radius stays inside the drifted cluster" pass "every other cluster still serving"
else
  check "blast radius stays inside the drifted cluster" fail "a cluster that was NOT drifted stopped serving"
fi

# 5. `latent` only: the whole point is that the drift was invisible while HAZL
#    was not using the cluster.
if [ "$MODE" = "latent" ]; then
  if [ "$served_target" -eq 0 ] && [ "$fed_err" -eq 0 ]; then
    check "latent: drift is invisible while the cluster is idle" pass \
      "0 errors, 0 requests to '${TARGET}' -- nothing surfaced it"
  else
    check "latent: drift is invisible while the cluster is idle" fail \
      "${fed_err} errors, ${served_target} reqs -- it surfaced without stress"
  fi
  printf '\n  Next step for the latent arm: apply FM3 brownout to force HAZL to\n'
  printf '  expand into %s, and show the failure appearing only under stress.\n' "$TARGET"
fi

bash "${REPO_ROOT}/verify/annotate.sh" end "$annot_start" \
  "FM5 ${MODE}: ${TARGET} off the trust anchor" "fm5" >/dev/null 2>&1 || true

printf '\nraw metric snapshots written to %s\n' "$RESULTS"
[ "$fails" -eq 0 ] || die "${fails} check(s) failed"
ok "FM5 (${MODE}) complete"
