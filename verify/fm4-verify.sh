#!/usr/bin/env bash
# FM4 experiment runner: region failure.
#
#   verify/fm4-verify.sh
#
# Partitions BOTH clusters in region-a (east and central) simultaneously and
# observes from west, the sole survivor. This is the reason the topology puts
# two clusters in one region: otherwise "region failure" is a cluster failure
# with a grander name.
#
# west is the observer deliberately, and it is also where the observability
# stack lives. An earlier version of this topology put west INSIDE region-a, so
# this experiment destroyed the cluster hosting Grafana: the failover worked
# perfectly and none of it was visible while it happened. See the topology note
# in clusters/lib.sh. The preflight below now refuses to run in that situation
# rather than discovering it afterwards.
#
# Four questions, in increasing order of interest:
#
#   1. Does the surviving region absorb 100% of traffic, and how fast?
#      Federated membership should go 9 -> 3 and throughput should hold.
#
#   2. How does losing two clusters at once compare to losing one? FM2 measured
#      6s for a graceful stop and 82s for a partition. If simultaneous loss is
#      materially slower, that matters: a region event is not N independent
#      cluster events.
#
#   3. What did west LOSE the ability to do? Its data plane is fine. But the
#      clusters that host half the mesh's control surface are gone, and the
#      links pointing at them are dead. This is the control-plane vs data-plane
#      distinction that DR plans routinely conflate: a cluster can serve traffic
#      perfectly while being unable to learn that anything has changed.
#
#   4. Could you SEE any of it? Measured, not assumed -- the dashboard is
#      probed throughout the failure window and reported as a check like any
#      other.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need linkerd kubectl docker

REGION="${REGION:-region-a}"

# An unknown region silently selects zero clusters -- the whole experiment then
# passes having tested nothing. Fail loudly instead.
[ -n "$(clusters_in_region "$REGION")" ] \
  || die "region '${REGION}' contains no clusters. Known regions: $(regions | tr '\n' ' ')"
OBSERVER="${OBSERVER:-west}"
SETTLE="${SETTLE:-120}"
RPS="${RPS:-30}"

# Where the observability stack lives. Must match HOST_CLUSTER in
# clusters/09-grafana.sh, and must NOT be in $REGION -- see the preflight below.
OBS_CLUSTER="${HOST_CLUSTER:-west}"
GRAFANA_NS="${GRAFANA_NS:-dr-observability}"

# Namespaced by PROFILE. Both arms used to write here, so running the second
# sweep destroyed the first one's raw snapshots -- Arm B overwrote Arm A on
# 2026-09-08 and only the SUMMARY files and TSDB archives survived.
RESULTS="${REPO_ROOT}/results/${PROFILE:-default}/fm4"
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

# Which service names carry each exposure mode from this observer. Read from
# clusters/lib.sh rather than written out here: mirror names are not uniform
# across clusters, and a runner that hardcodes them measures the wrong service
# the moment the topology changes -- reporting zero traffic rather than an error.
#
# west links to east and central, so its flat mirror target is app-flat-east, and it
# sources a gateway link to east. Both of those live in region-a, so both
# collapse with the region -- the same three-mode comparison FM2 produces, from
# a single injected fault.
FED_SVC="${FED_SVC:-$(modes_for "$OBSERVER" | awk '$1 == "federated" { print $2 }')}"
FLAT_SVC="${FLAT_SVC:-$(modes_for "$OBSERVER" | awk '$1 == "flat"      { print $2 }')}"
GW_SVC="${GW_SVC:-$(modes_for "$OBSERVER" | awk '$1 == "gateway"   { print $2 }')}"

[ -n "$GW_SVC" ] || die "'${OBSERVER}' resolves no gateway mirror, so this experiment
would compare two modes out of three. Add '${OBSERVER}:<target>' to GATEWAY_LINKS
in clusters/05-multicluster.sh and rebuild, or observe from a cluster that sources one."

dead_clusters="$(clusters_in_region "$REGION" | tr '\n' ' ')"
n_dead="$(clusters_in_region "$REGION" | grep -c .)"
n_alive="$(( $(clusters | grep -c .) - n_dead ))"

# Both derived from the topology table -- see federated_pool_size in
# clusters/lib.sh. Deriving one and hardcoding the other is worse than
# hardcoding both: change the replica count and the baseline assertion adapts
# while the convergence target silently does not, so the run fails on a number
# that has nothing to do with the region being killed.
expected_pool_before="$(federated_pool_size)"
per_cluster=$(( expected_pool_before / $(clusters | grep -c .) ))
expected_pool_after=$(( n_alive * per_cluster ))

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
}

delta() {  # <before> <after> <mode> <field: 1=total 2=errors 3=nontls>
  local b a
  # Per-series. Summing each snapshot and subtracting discards traffic served
  # by endpoints the fault removed -- see mode_totals_delta in verify/lib.sh.
  mode_totals_delta "$1" "$2" "$3" | awk -v f="$4" '{print $f}'
}

banner "FM4 region failure -- losing region '${REGION}' (${dead_clusters}), observed from '${OBSERVER}'"

# --- preflight: the recorder must be outside the blast radius ----------------
#
# This is five lines and it is the check that would have saved the first run of
# this experiment. "Install the observability extension" is a per-cluster
# action, someone has to pick a cluster, and nothing anywhere warns you when the
# cluster you picked is the one the game day destroys.
for c in $(clusters_in_region "$REGION"); do
  [ "$c" != "$OBS_CLUSTER" ] || die "the observability stack lives in '${c}', which this experiment destroys.
You would lose the recording of the event you are running this to record.
Either move it (HOST_CLUSTER in clusters/09-grafana.sh) or change which clusters
share a region (CLUSTER_TABLE in clusters/lib.sh)."
done
ok "observability stack is in '${OBS_CLUSTER}', outside region '${REGION}'"

# Probe the dashboard the same way 09-grafana.sh probes federation: from inside
# the cluster, so the result does not depend on a port-forward someone may or
# may not have running on the host.
grafana_up() {
  kubectl --context="$(ctx "$OBS_CLUSTER")" -n "$GRAFANA_NS" \
    exec deploy/dr-prometheus -c prometheus -- \
    wget -q -T 5 -O- "http://grafana.${GRAFANA_NS}.svc.cluster.local:3000/api/health" \
    >/dev/null 2>&1
}

obs_ok=0
obs_total=0

# Probe once before injecting, so "the dashboard died with the region" can be
# told apart from "the dashboard was never up". Without this, anyone running the
# experiment without `task grafana` gets a red FAIL that means nothing.
obs_available=yes
if grafana_up; then
  ok "dashboard reachable before injection"
else
  obs_available=no
  warn "dashboard not reachable before injection -- the observability check will be skipped.
Run 'task grafana' first if you want this experiment to prove the stack stayed up."
fi

sample_grafana() {
  [ "$obs_available" = "yes" ] || return 0
  obs_total=$(( obs_total + 1 ))
  # `if` rather than `&&`: under `set -e` a false compound is fatal.
  if grafana_up; then obs_ok=$(( obs_ok + 1 )); fi
}

require_meshed $(clusters)
require_baseline_view "$OBSERVER" "$FED_SVC" "$expected_pool_before"
# The variable that decided the convergence timings this runner no longer
# reports. Recorded because it is what the timing was really measuring.
base_active_at_start="$(active_endpoints "$OBSERVER" "$FED_SVC")"

require_control_run
require_settled "$OBSERVER" $dead_clusters
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
annot_start="$(bash "${REPO_ROOT}/verify/annotate.sh" start 2>/dev/null || true)"
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM4: region ${REGION} lost (${dead_clusters})" "fm4" "inject" >/dev/null 2>&1 || true
mark_phase injected

bash "${REPO_ROOT}/chaos/fm4-region-loss.sh" fail "$REGION"

# Prove the region is actually gone before measuring the failover.
#
# Counted from `docker ps` rather than kubectl: during a partition the API
# server does not answer, and "kubectl failed" and "the nodes are gone" are very
# different claims. A partition that silently did not apply would otherwise be
# reported as a flawless failover.
still_up=0
for c in $(clusters_in_region "$REGION"); do
  n="$(docker ps --filter "name=k3d-${c}-" --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
  still_up=$(( still_up + ${n:-0} ))
done
[ "$still_up" -eq 0 ] || die "region '${REGION}' still has ${still_up} running node container(s)
     after injection, so the partition did not fully apply. A failover measured
     against a region that is still up reads as a flawless result."
ok "region '${REGION}' is down (0 node containers running)"

# First probe immediately after the cut, while the survivor is still working out
# that half its mesh is gone. The convergence loop below is deliberately left
# untouched -- adding a ~1s exec to a 3s poll would perturb the timing this
# experiment exists to measure.
sample_grafana

# --- convergence ------------------------------------------------------------

banner "measuring convergence"
# Traffic-based, not endpoint-count-based -- the same measure FM2 uses, and for
# the same reason (see converge_by_traffic in verify/lib.sh).
#
# This experiment used to poll endpoint_pool until it read expected_pool_after,
# and on 2026-08-27 that check FAILED while every behavioural signal said the
# failover was complete: 100% throughput, zero errors, zero requests served by
# the dead region. The pool count was the only thing claiming otherwise, and it
# was wrong. Timing convergence on a signal that misreports during exactly the
# fault it is timing produces a red check with no defect behind it -- and the
# temptation is then to relax the threshold rather than replace the instrument.
log "waiting for traffic to region '${REGION}' (${dead_clusters}) to stop"
# Completion, NOT timing -- and this is the experiment that proved why. Two runs
# of this exact fault on this exact rig reported 34s and 1s, decided by whether
# HAZL was using the partitioned endpoints when it landed: east 104 / central 54
# in the slow run, east 0 / central 0 in the fast one. A number that swings 34x
# on a variable the experiment does not control is not a property of the fault.
converge_out="$(converge_by_traffic "$OBSERVER" "$FED_SVC" "$dead_clusters" "$SETTLE" || true)"
t_converged="$(echo "$converge_out" | awk '{print $1}')"

if [ -n "$t_converged" ]; then
  ok "traffic to region '${REGION}' stopped (baseline active pool was ${base_active_at_start:-?})"
  bash "${REPO_ROOT}/verify/annotate.sh" point \
    "FM4: traffic to ${REGION} stopped" \
    "fm4" "converged" >/dev/null 2>&1 || true
else
  warn "traffic to region '${REGION}' had not stopped within ${SETTLE}s"
fi
# Printed, never checked. The count is worth recording because the gap between
# it and the traffic measure is itself a finding.
printf '  endpoint counts for reference: available=%s active=%s (want %s)\n' \
  "$(endpoint_pool "$OBSERVER" "$FED_SVC")" \
  "$(active_endpoints "$OBSERVER" "$FED_SVC")" \
  "$expected_pool_after"

log "holding ${SETTLE}s to accumulate post-failure traffic"
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM4: steady state under regional loss" "fm4" "measuring" >/dev/null 2>&1 || true

# Hold in increments rather than one sleep, so the dashboard is probed across
# the whole window. Throughput math uses real timestamps (t_during - t_baseline)
# rather than SETTLE, so the extra time the probes cost does not skew it.
# Survivors, and how much they were serving when the fault landed. The guard
# below aborts if one of them goes silent -- see guard_blast_radius.
survivors="$(clusters | grep -vxF -f <(clusters_in_region "$REGION") || true)"
hold_deadline=$(( $(now) + SETTLE ))
while [ "$(now)" -lt "$hold_deadline" ]; do
  sample_grafana
  # shellcheck disable=SC2086
  if ! guard_blast_radius "$OBSERVER" "$FED_SVC" 0 $survivors; then
    warn "aborting the measurement window early; the restore below still runs"
    break
  fi
  sleep 10
done
t_during="$(now)"
report_state during

# --- question 3: what can the survivor no longer do? ------------------------

banner "control plane vs data plane in the survivor"

printf '\nLinks in %s (these point at clusters that no longer exist):\n' "$OBSERVER"
kubectl --context="$(ctx "$OBSERVER")" -n linkerd-multicluster get links \
  -o custom-columns='LINK:.metadata.name,GATEWAY:.spec.gatewayAddress' --no-headers 2>/dev/null \
  | sed 's/^/  /'

printf '\nMirror controller state:\n'
for dead in $(clusters_in_region "$REGION"); do
  ready="$(kubectl --context="$(ctx "$OBSERVER")" -n linkerd-multicluster \
    get deploy "controller-${dead}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  printf '  controller-%-10s readyReplicas=%s\n' "$dead" "${ready:-0}"
done

printf '\n  The data plane in %s keeps serving throughout. Whether it can still\n' "$OBSERVER"
printf '  LEARN about topology changes is a separate question -- and separate\n'
printf '  dashboards.\n'

# --- evaluate ---------------------------------------------------------------

banner "results"

elapsed=$(( t_during - t_baseline ))
expected=$(( RPS * elapsed ))

fed_tp="$(delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" 1)"
fed_err="$(delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" 2)"
fed_tls="$(nontls_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC")"
flat_tp="$(delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC" 1)"
gw_tp="$(delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC" 1)"

pct() { [ "$2" -eq 0 ] && echo 0 || echo $(( $1 * 100 / $2 )); }

printf '\nthroughput over the %ss window (expected ~%s per mode):\n' "$elapsed" "$expected"
printf '  %-20s %6s reqs  (%s%%)   federated\n'      "$FED_SVC" "$fed_tp"  "$(pct "$fed_tp" "$expected")"
printf '  %-20s %6s reqs  (%s%%)   flat mirror\n'    "$FLAT_SVC"        "$flat_tp" "$(pct "$flat_tp" "$expected")"
printf '  %-20s %6s reqs  (%s%%)   gateway mirror\n' "$GW_SVC"          "$gw_tp"   "$(pct "$gw_tp" "$expected")"

printf '\nfederated traffic DURING the failure (delta from baseline):\n'
distribution_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" \
  "$FED_SVC" | sed 's/^/  /'

printf '\n%-46s %s\n' CHECK RESULT
printf -- '-------------------------------------------------------------\n'

fails=0
check() {
  if [ "$2" = "pass" ]; then printf '%-46s \033[1;32mPASS\033[0m  %s\n' "$1" "$3"
  else printf '%-46s \033[1;31mFAIL\033[0m  %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

if [ -n "$t_converged" ]; then
  check "failover completes (traffic to dead region stops)" pass "yes -- baseline active pool ${base_active_at_start:-?}"
else
  check "failover completes (traffic to dead region stops)" fail "not within ${SETTLE}s"
fi

if [ "$(pct "$fed_tp" "$expected")" -ge 80 ]; then
  check "surviving region absorbs the traffic" pass "$(pct "$fed_tp" "$expected")% of expected"
else
  check "surviving region absorbs the traffic" fail "only $(pct "$fed_tp" "$expected")%"
fi

fed_err_pm=$(( fed_err * 1000 / (fed_tp > 0 ? fed_tp : 1) ))
if [ "$fed_err_pm" -le 20 ]; then
  check "federated errors bounded" pass "${fed_err} of ${fed_tp} ($((fed_err_pm/10)).$((fed_err_pm%10))%)"
else
  check "federated errors bounded" fail "${fed_err} of ${fed_tp} ($((fed_err_pm/10)).$((fed_err_pm%10))%)"
fi

if [ "$fed_tls" -eq 0 ]; then
  check "mTLS continuity through regional failover" pass "0 non-mTLS"
else
  check "mTLS continuity through regional failover" fail "${fed_tls} non-mTLS"
fi

# All federated traffic must now be served by the survivor only.
served_dead="$(distribution_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" \
  "$FED_SVC" | awk -v d="$(clusters_in_region "$REGION" | tr '\n' '|')" '
    $1 != "TOTAL" && $1 ~ ("^(" substr(d,1,length(d)-1) ")$") {s+=$2} END {print s+0}')"
if [ "$served_dead" -lt "$((expected / 20))" ]; then
  check "no traffic served by the dead region" pass "${served_dead} reqs (pre-convergence only)"
else
  check "no traffic served by the dead region" fail "${served_dead} reqs"
fi

# The experiment is only worth running if you could watch it happen.
if [ "$obs_available" != "yes" ]; then
  printf '%-46s \033[1;33mSKIP\033[0m  %s\n' \
    "observability stack survived the region loss" "stack was not up at baseline"
elif [ "$obs_ok" -eq "$obs_total" ]; then
  check "observability stack survived the region loss" pass "${obs_ok}/${obs_total} probes"
else
  check "observability stack survived the region loss" fail \
    "${obs_ok}/${obs_total} probes ($(pct "$obs_ok" "$obs_total")%)"
fi

# --- restore ----------------------------------------------------------------

banner "restoring"
bash "${REPO_ROOT}/verify/annotate.sh" end "$annot_start" \
  "FM4: region ${REGION} down (converged in ${t_converged:-?}s)" "fm4" >/dev/null 2>&1 || true

bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM4: restoring region ${REGION}" "fm4" "restore" >/dev/null 2>&1 || true
mark_phase restored

bash "${REPO_ROOT}/chaos/fm4-region-loss.sh" restore "$REGION"

log "checking whether recovered workloads came back meshed"
bash "${REPO_ROOT}/verify/meshed.sh" >/dev/null 2>&1 \
  || { warn "unmeshed pods after recovery -- remeshing"
       bash "${REPO_ROOT}/verify/meshed.sh" --fix 2>&1 | grep -E 'unmeshed|ok ' | head -6 || true; }

log "waiting for membership to recover"
t_restore="$(now)"
deadline=$(( t_restore + 300 ))
t_recover=""
while [ "$(now)" -lt "$deadline" ]; do
  # Destination view, not the balancer pool -- same reason as everywhere else in
  # this file. See the note on FM2's recovery loop.
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
  bash "${REPO_ROOT}/verify/annotate.sh" point \
    "FM4: fully recovered (${t_recover}s after restore)" "fm4" "recovered" >/dev/null 2>&1 || true
else
  warn "did not fully recover within 300s (destination view=${view:-?}, balancer pool=$(endpoint_pool "$OBSERVER" "$FED_SVC"))"
  bash "${REPO_ROOT}/verify/annotate.sh" point \
    "FM4: did NOT fully recover (view=${view:-?})" "fm4" "recovered" >/dev/null 2>&1 || true
fi

report_state recovered

echo
printf 'raw metric snapshots written to %s\n' "$RESULTS"
[ "$fails" -eq 0 ] || die "${fails} check(s) failed"
ok "FM4 complete"
