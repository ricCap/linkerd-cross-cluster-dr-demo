#!/usr/bin/env bash
# FM2 experiment runner: cluster failure.
#
#   verify/fm2-verify.sh graceful
#   verify/fm2-verify.sh hard
#
# Runs the full cycle -- baseline, inject, measure convergence, restore -- and
# prints a pass/fail table. Measurement is taken from west's load generator,
# which is the surviving observer when `east` is the target.
#
# What we expect, and why each is interesting:
#
#   federated (app-federated)
#     Endpoint pool 9 -> 6, traffic rebalances to the two survivors, and the
#     error count stays at zero. No client change, no config change.
#
#   flat mirror (app-flat-east)
#     Hard failure. The client is pinned to one cluster's copy; there is nothing
#     to fail over to. This is the control that shows federation is doing work.
#
#   gateway mirror (app-gateway-east-gw)
#     Also fails, but through the gateway, so the failure mode and timing differ.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need linkerd kubectl docker

VARIANT="${1:-graceful}"
TARGET="${TARGET:-east}"
OBSERVER="${OBSERVER:-west}"
SETTLE="${SETTLE:-90}"

# Which service names carry each exposure mode from this observer. Read from
# clusters/lib.sh rather than written out here, because the mirror names are not
# uniform across clusters and a runner that hardcodes them measures the wrong
# service the moment the topology changes -- silently, as zero traffic.
FED_SVC="$(modes_for "$OBSERVER" | awk '$1 == "federated" { print $2 }')"
FLAT_SVC="$(modes_for "$OBSERVER" | awk '$1 == "flat"      { print $2 }')"
GW_SVC="$(modes_for "$OBSERVER" | awk '$1 == "gateway"   { print $2 }')"

[ -n "$GW_SVC" ] || die "'${OBSERVER}' resolves no gateway mirror, so this experiment
would compare two modes out of three. Add '${OBSERVER}:<target>' to GATEWAY_LINKS
in clusters/05-multicluster.sh and rebuild, or observe from a cluster that sources one."

case "$VARIANT" in graceful|hard) ;; *) die "usage: fm2-verify.sh <graceful|hard>";; esac

# Namespaced by PROFILE. Both arms used to write here, so running the second
# sweep destroyed the first one's raw snapshots -- Arm B overwrote Arm A on
# 2026-09-08 and only the SUMMARY files and TSDB archives survived.
RESULTS="${REPO_ROOT}/results/${PROFILE:-default}/fm2-${VARIANT}"
mkdir -p "$RESULTS"

# Record WHICH cluster these snapshots were taken from.
#
# The runners do not agree on this and should not have to: FM1 reads the proxy
# in the cluster whose control plane it breaks, the others read a surviving
# observer. Anything replaying the snapshots later cannot tell from the files,
# and picking wrong is silent -- the mirror service names differ per cluster, so
# the wrong observer measures a service that was never exercised and reports it
# as zero traffic.
echo "$OBSERVER" > "${RESULTS}/observer"
# Record the FLAVOR these snapshots were taken under, for the same reason the
# observer is recorded: a replay cannot tell from the files, and picking wrong is
# silent. It is not cosmetic -- endpoints{ready} means the whole pool on OSS and
# HAZL's active subset on BEL (see verify/metrics.md), so a BEL run read as OSS
# is misread in a specific, confident, wrong direction.
echo "${LINKERD_FLAVOR:-oss}" > "${RESULTS}/flavor"
# The PROFILE too, for the same reason the flavor is recorded: a run read
# under the wrong one is misread confidently. Arm A and Arm B write to the
# SAME results directory, so the second overwrites the first -- the durable
# record of a sweep is its results/run-<date>*/SUMMARY.md and its TSDB
# archive, not these snapshots.
echo "${PROFILE:-default}" > "${RESULTS}/profile"

# Record the node address table alongside the snapshots.
#
# Gateway mirrors resolve to a NODE address rather than a pod IP, so attributing
# them to a cluster needs this table (see cluster_of_ip in clusters/lib.sh).
# Docker assigns those addresses, and they change across rebuilds -- so
# attributing an old run with a current table is not a small error, it is a
# confident wrong answer. Copy it now or the run can never be read back.
#
# Regenerate rather than skip when it is absent. 05-multicluster.sh writes it at
# setup, but a later step can remove clusters/.generated/ and nothing notices --
# after which every gateway endpoint quietly files under "other", here and in
# distribution_delta. Rebuilding it costs one docker inspect per node.
[ -f "$(ip_state_file)" ] || save_node_ips $(clusters)
cp -f "$(ip_state_file)" "${RESULTS}/node-ips.txt" 2>/dev/null || true

# Derived from clusters/lib.sh, not hardcoded: the topology table is meant to be
# the single source of truth, and a runner asserting a literal 9 dies on a
# baseline check that has nothing to do with what it is testing.
expected_pool_before="$(federated_pool_size)"
expected_pool_after=$(( expected_pool_before - expected_pool_before / $(clusters | wc -w) ))

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

report_state() {
  local label="$1" metrics mode t
  metrics="$(proxy_responses "$OBSERVER")"
  printf '\n[%s]  pool(%s)=%s\n' "$label" "$FED_SVC" "$(endpoint_pool "$OBSERVER" "$FED_SVC")"
  for mode in "$FED_SVC" "$FLAT_SVC" "$GW_SVC"; do
    t="$(mode_totals "$metrics" "$mode")"
    # shellcheck disable=SC2086
    printf '  %-20s total=%-8s errors=%-8s non-mTLS=%s\n' "$mode" $t
  done
  echo "$metrics" > "${RESULTS}/${label}.metrics"
  record_node_state "${RESULTS}/${label}.nodes"

  # The client's own account of the same moment. Captured at every snapshot so
  # the window can be read back without re-running anything.
  k6_client_view "$OBSERVER" > "${RESULTS}/${label}.client"
  # shellcheck disable=SC2046
  printf '  %-20s attempted=%s client_errors=%s dropped=%s failed=%s\n' "client(k6)" \
    $(cat "${RESULTS}/${label}.client")
}

# Delta in errors for a mode between two metric snapshots.
# Guarded: a proxy counter that decreased means the loadgen pod restarted and
# every number from this window is meaningless. See counter_delta in lib.sh.
error_delta() {
  local before after mode="$3"
  # Per-series. Summing each snapshot and subtracting discards traffic served
  # by endpoints the fault removed -- see mode_totals_delta in verify/lib.sh.
  mode_totals_delta "$1" "$2" "$mode" | awk '{print $2}'
}

banner "FM2 cluster failure -- ${VARIANT} loss of '${TARGET}', observed from '${OBSERVER}'"

# --- baseline ---------------------------------------------------------------

require_meshed $(clusters)
require_baseline_view "$OBSERVER" "$FED_SVC" "$expected_pool_before"
# What HAZL was actually using when the fault landed. This is the variable that
# decided the convergence timings we no longer report, so it is worth recording.
base_active_at_start="$(active_endpoints "$OBSERVER" "$FED_SVC")"

require_control_run
require_settled "$OBSERVER" "$TARGET"
t_baseline="$(now)"
# Label BEFORE sampling starts. The phase file persists between runs, so a
# sampler started first records its opening samples under the PREVIOUS run's
# phase -- observed as a stray "restored" at the head of a baseline window.
mark_phase baseline
sampler_start
trap sampler_stop EXIT
report_state baseline

# --- inject -----------------------------------------------------------------

banner "injecting"
t_inject="$(now)"
# Mark the fault on the Grafana timeline. The region is closed at restore, so
# the dashboards shade the whole outage rather than showing an unexplained
# cliff -- which is the difference between a screenshot that argues something
# and one that merely looks dramatic.
annot_start="$(bash "${REPO_ROOT}/verify/annotate.sh" start 2>/dev/null || true)"
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM2 ${VARIANT}: ${TARGET} lost" "fm2" "inject" >/dev/null 2>&1 || true
mark_phase injected

bash "${REPO_ROOT}/chaos/fm2-cluster-loss.sh" "$VARIANT" "$TARGET"

# --- measure convergence ----------------------------------------------------

banner "measuring convergence"
# Traffic-based, not endpoint-count-based: see converge_by_traffic in
# verify/lib.sh for why the count is unreliable under HAZL.
log "waiting for traffic to '${TARGET}' to stop"
# Completion, NOT timing.
#
# converge_by_traffic still detects that failover happened -- it is the only
# reliable signal for that -- but its elapsed value is no longer reported as a
# result. Two FM4 runs of the same fault on the same rig gave 34s and 1s,
# decided entirely by whether HAZL happened to be using the partitioned
# endpoints when the fault landed (east 104 / central 54 in the slow run, east 0
# / central 0 in the fast one). A number that swings 34x on a variable the
# experiment does not control is not a property of the fault.
#
# The active pool at baseline IS recorded, because that is the variable the
# timing was really measuring.
converge_out="$(converge_by_traffic "$OBSERVER" "$FED_SVC" "$TARGET" "$SETTLE" || true)"
t_converged="$(echo "$converge_out" | awk '{print $1}')"

if [ -n "$t_converged" ]; then
  ok "traffic to '${TARGET}' stopped (baseline active pool was ${base_active_at_start:-?})"
else
  warn "traffic to '${TARGET}' had not stopped within ${SETTLE}s"
fi
printf '  endpoint counts for reference: available=%s active=%s\n' \
  "$(endpoint_pool "$OBSERVER" "$FED_SVC")" \
  "$(active_endpoints "$OBSERVER" "$FED_SVC")"

# Let traffic run against the converged topology so error deltas are meaningful.
log "holding ${SETTLE}s to accumulate post-failure traffic"
sleep "$SETTLE"
t_during="$(now)"
report_state during

# --- evaluate ---------------------------------------------------------------

banner "results"

fed_err="$(error_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC")"
flat_err="$(error_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC")"
gw_err="$(error_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC")"

# Throughput, not error count, is the honest measure of these failures.
#
# When a mirrored service loses every endpoint, the proxy has nowhere to send
# requests: they sit in the balancer queue until the client gives up. A request
# that never gets a response never increments response_total, so the error
# counter stays near zero while the service is in fact completely dead. In the
# first run of this experiment the flat mirror logged 2 errors -- and served 55
# requests where 2700 were expected. Error rate said "fine"; throughput said
# "gone". Report throughput.
# Expected volume must be based on ELAPSED time between the two snapshots, not
# on the hold duration. The window spans convergence *plus* the hold, and
# convergence is 6s for a graceful stop but 82s for a hard partition -- using
# SETTLE alone reported 190% of expected for a service that was merely healthy.
elapsed="$(( t_during - t_baseline ))"

# TWO denominators, because they answer different questions and only one of them
# is a measurement.
#
#   nominal  = RPS x elapsed. What the generator was CONFIGURED to offer.
#   attempted = what k6 actually issued, from its own counter.
#
# These diverge exactly when it matters. constant-arrival-rate cannot start an
# iteration without a free VU, and a hanging request holds its VU for the whole
# timeout -- so during the failures measured here the generator offers less than
# RPS and every "% of expected" against the nominal overstates the shortfall.
# Report against attempted where k6 can be reached, and say which was used.
nominal="$(( ${RPS:-30} * elapsed ))"

c_before="$(awk '{print $1}' "${RESULTS}/baseline.client" 2>/dev/null)"
c_after="$(awk '{print $1}' "${RESULTS}/during.client" 2>/dev/null)"
d_after="$(awk '{print $3}' "${RESULTS}/during.client" 2>/dev/null)"
d_before="$(awk '{print $3}' "${RESULTS}/baseline.client" 2>/dev/null)"

# k6 counts every exposure mode in ONE counter, so divide by the number of modes
# this observer actually drives to compare against a single mode's throughput.
# Derived, not hardcoded: east sources two modes, not three (it has no gateway
# link), so a literal 3 understates its attempted rate by a third.
n_modes="$(modes_for "$OBSERVER" | wc -l | tr -d ' ')"
if [ -n "${c_before:-}" ] && [ -n "${c_after:-}" ] && [ "$c_before" != "-" ] && [ "$c_after" != "-" ]; then
  attempted=$(( ( ${c_after%%.*} - ${c_before%%.*} ) / n_modes ))
  # Guarded: these read "-" when the k6 API is unreachable.
  case "${d_after%%.*}" in ''|*[!0-9]*) d_after=0 ;; esac
  case "${d_before%%.*}" in ''|*[!0-9]*) d_before=0 ;; esac
  dropped=$(( ${d_after%%.*} - ${d_before%%.*} ))
  expected="$attempted"
  basis="attempted by the client"
  if [ "$dropped" -gt 0 ]; then
    warn "k6 dropped ${dropped} iterations during this window -- it could not
     start them for lack of VUs. Percentages are against what the client
     ACTUALLY issued; the nominal ${nominal}/mode was never offered."
  fi
else
  expected="$nominal"
  basis="nominal RPS x elapsed -- k6 API unreachable, see clusters/08-load.sh"
  warn "could not read the load generator's own counters; falling back to the
     nominal rate. This cannot distinguish a hung request from an unsent one."
fi

throughput_delta() {
  # Per-series. Summing each snapshot and subtracting discards traffic served by
  # endpoints the fault removed -- see mode_totals_delta in verify/lib.sh.
  #
  # No counter_delta wrapper here any more. It guarded against a negative total,
  # and mode_totals_delta already drops any series that went backwards, so the
  # wrapper could no longer fire. A guard that cannot fail reads like protection
  # and provides none.
  mode_totals_delta "$1" "$2" "$3" | awk '{print $1}'
}

fed_tp="$(throughput_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC")"
flat_tp="$(throughput_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC")"
gw_tp="$(throughput_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC")"

pct() { [ "$2" -eq 0 ] && echo 0 || echo $(( $1 * 100 / $2 )); }

printf '\nthroughput over the %ss failure window (expected ~%s per mode, basis: %s):\n' \
  "$elapsed" "$expected" "$basis"
printf '  %-20s %6s reqs  (%s%% of expected)\n' "$FED_SVC"  "$fed_tp"  "$(pct "$fed_tp" "$expected")"
printf '  %-20s %6s reqs  (%s%% of expected)\n' "$FLAT_SVC" "$flat_tp" "$(pct "$flat_tp" "$expected")"
printf '  %-20s %6s reqs  (%s%% of expected)\n' "$GW_SVC"   "$gw_tp"   "$(pct "$gw_tp" "$expected")"

# Delta, not cumulative: see the comment on distribution_delta in verify/lib.sh.
printf '\nfederated traffic DURING the failure (delta from baseline):\n'
distribution_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" \
  "$FED_SVC" | sed 's/^/  /'

printf '\n  (baseline for comparison was an even split across all three)\n'

printf '\n%-46s %s\n' CHECK RESULT
printf -- '-------------------------------------------------------------\n'

fails=0
check() {
  if [ "$2" = "pass" ]; then printf '%-46s \033[1;32mPASS\033[0m  %s\n' "$1" "$3"
  else printf '%-46s \033[1;31mFAIL\033[0m  %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

if [ -n "$t_converged" ]; then
  # Resolution is reported with the number on purpose. A bare "6s" invites being
  # quoted against the 82s partition as a precise 13x; it is not, and the
  # tolerance is the only thing that says so.
  check "traffic to the dead cluster stops" pass "yes -- baseline active pool ${base_active_at_start:-?}"
else
  check "traffic to the dead cluster stops" fail "not within ${SETTLE}s"
fi

# The two variants have genuinely different expectations, and flattening them
# into one pass/fail hides the most interesting result in this experiment.
#
# A graceful stop closes connections, so failover is clean: zero errors.
# A hard partition blackholes packets -- nothing is refused, so the system must
# wait for timeouts before it can even know the cluster is gone. Errors during
# that detection window are expected and unavoidable. What matters is that they
# stay a small fraction of traffic and stop once membership converges.
fed_err_pct=$(( fed_err * 1000 / (fed_tp > 0 ? fed_tp : 1) ))   # per-mille
if [ "$VARIANT" = "graceful" ]; then
  if [ "$fed_err" -eq 0 ]; then
    check "federated absorbs failure with zero errors" pass "0 new errors"
  else
    check "federated absorbs failure with zero errors" fail "${fed_err} new errors"
  fi
else
  if [ "$fed_err_pct" -le 20 ]; then   # <= 2%
    check "federated errors bounded during detection" pass \
      "${fed_err} errors of ${fed_tp} reqs ($((fed_err_pct / 10)).$((fed_err_pct % 10))%)"
  else
    check "federated errors bounded during detection" fail \
      "${fed_err} errors of ${fed_tp} reqs ($((fed_err_pct / 10)).$((fed_err_pct % 10))%)"
  fi
fi

if [ "$(pct "$fed_tp" "$expected")" -ge 80 ]; then
  check "federated holds throughput" pass "$(pct "$fed_tp" "$expected")% of expected"
else
  check "federated holds throughput" fail "only $(pct "$fed_tp" "$expected")% of expected"
fi

if [ "$(pct "$flat_tp" "$expected")" -lt 20 ]; then
  check "flat mirror collapses (control)" pass "$(pct "$flat_tp" "$expected")% of expected, ${flat_err} errors"
else
  check "flat mirror collapses (control)" fail "still serving $(pct "$flat_tp" "$expected")%"
fi

if [ "$(pct "$gw_tp" "$expected")" -lt 20 ]; then
  check "gateway mirror collapses (control)" pass "$(pct "$gw_tp" "$expected")% of expected, ${gw_err} errors"
else
  check "gateway mirror collapses (control)" fail "still serving $(pct "$gw_tp" "$expected")%"
fi

nontls="$(nontls_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC")"
if [ "$nontls" -eq 0 ]; then
  check "mTLS continuity through failover" pass "0 non-mTLS requests"
else
  check "mTLS continuity through failover" fail "${nontls} non-mTLS requests"
fi

# --- restore ----------------------------------------------------------------

banner "restoring"
bash "${REPO_ROOT}/verify/annotate.sh" end "$annot_start" \
  "FM2 ${VARIANT}: ${TARGET} down" "fm2" >/dev/null 2>&1 || true
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM2 ${VARIANT}: restoring ${TARGET}" "fm2" "restore" >/dev/null 2>&1 || true
mark_phase restored

bash "${REPO_ROOT}/chaos/fm2-cluster-loss.sh" restore "$TARGET"

# A recovered cluster frequently comes back with unmeshed workloads -- pods that
# were admitted while the proxy injector was still starting. They look healthy
# and serve plaintext. Fix it as part of restore rather than leaving the
# environment quietly broken for the next experiment.
log "checking whether recovered workloads came back meshed"
bash "${REPO_ROOT}/verify/meshed.sh" >/dev/null 2>&1 \
  || { warn "unmeshed pods after recovery -- remeshing (this is a finding, not a workaround)"
       bash "${REPO_ROOT}/verify/meshed.sh" --fix 2>&1 | grep -E 'unmeshed|ok ' | head -8 || true; }

log "waiting for membership to recover"
t_restore="$(now)"
# Recovery is timed on the DESTINATION view, not the balancer's.
#
# This polled endpoint_pool, which is adaptive_endpoints under BEL and is not a
# membership signal. That matters here more than anywhere else, because the
# recovery finding is one of the strongest in the exercise: FINDINGS records
# "membership did not recover inside the observation window -- the pool sat at 7
# of 9 for the entire 240s and the runner gave up", with the note that checking
# again afterwards showed 9, so it was "slow, not stuck".
#
# That whole observation was read off a metric already established as
# unreliable. It may still be true; it is not currently evidence. Re-measure it
# here before quoting it.
deadline=$(( t_restore + 240 ))
t_recover=""
while [ "$(now)" -lt "$deadline" ]; do
  view="$(destination_endpoints "$OBSERVER" "$FED_SVC")"
  printf '\r  t+%-3ss  destination view = %-4s (want %s)' \
    "$(( $(now) - t_restore ))" "${view:-?}" "$expected_pool_before"
  if [ "${view:-0}" = "$expected_pool_before" ]; then
    t_recover="$(( $(now) - t_restore ))"; break
  fi
  sleep 5
done
echo
if [ -n "$t_recover" ]; then
  ok "recovered to ${expected_pool_before} endpoints in ${t_recover}s"
else
  warn "did not recover within 240s (destination view=${view:-?}, balancer pool=$(endpoint_pool "$OBSERVER" "$FED_SVC"))"
fi

report_state recovered

echo
printf 'raw metric snapshots written to %s\n' "$RESULTS"
[ "$fails" -eq 0 ] || die "${fails} check(s) failed"
ok "FM2 (${VARIANT}) complete"
