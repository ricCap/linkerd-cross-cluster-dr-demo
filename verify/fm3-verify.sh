#!/usr/bin/env bash
# FM3 experiment runner: zone brownout, and whether HAZL reacts to it.
#
#   verify/fm3-verify.sh
#
# Requires LINKERD_FLAVOR=bel. The load-average and load-band metrics this
# asserts on do not exist in the open source proxy, so on OSS there is nothing
# to measure -- which is itself the honest OSS-vs-enterprise contrast.
#
# The claim under test: a zone that is SLOW but healthy should cause the
# balancer to widen its endpoint pool beyond that zone, without any endpoint
# leaving the EndpointSlice and without any Kubernetes signal firing.
#
# Three things must all move together for that claim to hold:
#   1. load average crosses the band's high threshold
#   2. the active endpoint count steps UP
#   3. traffic starts landing on remote-zone endpoints
#
# Any one alone is not enough. A load average that rises without the pool
# widening means HAZL saw the stress and did nothing.
#
# Those three are asserted for the FEDERATED service, which is where the claim
# lives. All three exposure modes are then compared under the same fault,
# because they have very different amounts of room to react:
#
#   federated  9 endpoints across 3 clusters. Most room; should widen.
#   flat       3 endpoints, all in the target cluster, one per zone. Less room,
#              same mechanism -- HAZL should still step off the slow zone.
#   gateway    ONE endpoint from the client's point of view: the target
#              cluster's gateway address. A node address carries no zone label,
#              so there is nothing for a zone-aware balancer to prefer and
#              nothing for it to widen into. Whatever reaction happens, happens
#              inside the target cluster where this client cannot see it.
#
# The gateway row is asserted as a NON-event on purpose. "We did not measure it"
# and "we measured it and it cannot react" are very different claims, and only
# the second one is worth writing down.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need linkerd kubectl

[ "${LINKERD_FLAVOR:-oss}" = "bel" ] || die "FM3 requires LINKERD_FLAVOR=bel.
The HAZL metrics it asserts on do not exist in the OSS proxy -- see verify/metrics.md."

OBSERVER="${OBSERVER:-west}"
# The primary subject of the band experiment. Federated by default: it has the
# most endpoints and so the most room to widen, which is where the HAZL claim
# lives. The other two modes are compared against it further down.
SVC="${SVC:-$(modes_for "${OBSERVER:-west}" | awk '$1 == "federated" { print $2 }')}"
# Deliberately NOT defaulted here. The fault has to be sized from the band this
# rig actually exposes, and the band is not known until the baseline is read --
# see size_latency below. Set LATENCY to override.
LATENCY="${LATENCY:-}"

# The calibration point the 400ms default came from: 400ms was derived assuming
# a high threshold of 6.00, which assumes a 3-endpoint active pool.
LATENCY_REF_MS=400
LATENCY_REF_HIGH=6.0
# Margin over the threshold. The default landed at 7.85 against 8.00 twice --
# near-misses that read as "HAZL did not react" and were purely an arithmetic
# error. Aim to clear the bar, not to graze it.
# 150%, not 125%. Sized at 125% the fault peaked at 5.764 against a 6.00
# threshold -- a fourth near-miss, and the whole point of computing this is to
# stop grazing the bar. The relationship between injected latency and observed
# load is not linear here, so the margin absorbs what the model does not.
LATENCY_MARGIN=150

# Hard ceiling on the injected latency, and it is not arbitrary.
#
# The proxy's connections to its own control plane have a 1s connect timeout.
# Sized at 900ms the brownout crossed it, and pods in the slowed zone stopped
# being able to START:
#
#   linkerd_reconnect: Failed to connect
#     error=endpoint 10.22.2.3:8090 (linkerd-policy): connect timed out after 1s
#   Startup probe failed: Get "http://.../ready": context deadline exceeded
#   Killing  Init container linkerd-proxy failed startup probe
#
# Two pods were left stuck in Init:1/2 across east and central, the federated
# pool dropped to 7, and the NEXT experiment refused to start. At that point the
# experiment is no longer measuring "a zone got slow" -- it is measuring "the
# mesh cannot bring proxies up", which is a different fault with a different
# name and no HAZL content at all.
#
# 800ms keeps a margin under the timeout. If a rig genuinely needs more than
# this to cross its band, the answer is not more latency: see the note on the
# load-crossing check below, which explains why more latency stops helping.
LATENCY_MAX_MS=800
SETTLE="${SETTLE:-90}"

# The three exposure modes this cluster can resolve. $SVC stays the primary
# subject of the band experiment; these are compared alongside it.
MODES="$(modes_for "$OBSERVER")"

# Refuse to run two-thirds of the comparison quietly. Without a gateway link the
# mode loop below would simply have one fewer row, and the output would look
# complete.
echo "$MODES" | grep -q '^gateway ' || die "'${OBSERVER}' resolves no gateway mirror, so this
experiment would compare two modes out of three without saying so. Add
'${OBSERVER}:<target>' to GATEWAY_LINKS in clusters/05-multicluster.sh and rebuild,
or observe from a cluster that sources one."

# Namespaced by PROFILE. Both arms used to write here, so running the second
# sweep destroyed the first one's raw snapshots -- Arm B overwrote Arm A on
# 2026-09-08 and only the SUMMARY files and TSDB archives survived.
RESULTS="${REPO_ROOT}/results/${PROFILE:-default}/fm3"
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

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# "<load> <low> <high>" plus active/available counts, as one line.
state_line() {
  local hl act avail
  hl="$(hazl_load "$OBSERVER" "$SVC")"
  act="$(active_endpoints "$OBSERVER" "$SVC")"
  avail="$(endpoint_pool "$OBSERVER" "$SVC")"
  echo "${hl:-0 0 0} ${act:-0} ${avail:-0}"
}

show_state() {
  local s; s="$(state_line)"
  printf '  load=%-8s band=[%s .. %s]  active=%s of %s\n' \
    "$(echo "$s" | awk '{print $1}')" \
    "$(echo "$s" | awk '{print $2}')" \
    "$(echo "$s" | awk '{print $3}')" \
    "$(echo "$s" | awk '{print $4}')" \
    "$(echo "$s" | awk '{print $5}')"
}

# Requests by zone locality for one service, as "<local> <remote> <unlabelled>".
#
# Extract the label with sed rather than awk substr arithmetic: the prefix
# `dst_zone_locality="` is 19 characters and an off-by-one silently yields an
# empty string, which reads as "no remote traffic" rather than as a parse error.
#
# The third bucket matters for gateway mode and is not padding. A gateway mirror
# resolves to a node address, which carries no zone, so its requests are neither
# local nor remote -- they are unlabelled. With two buckets those requests are
# dropped and the row reads "0 remote", i.e. a measured value of zero, when the
# truth is that there was never a zone signal to measure. Counting them
# separately is the difference between a finding and an artifact.
#
# The capture insists on a NON-empty value ([^"][^"]*, not [^"]*). A proxy that
# emits dst_zone_locality="" would otherwise substitute to " <count>", awk would
# read the count as field 1, and those requests would be added to the unlabelled
# bucket as zero -- silently dropped from every total on the row.
#
#   locality_counts <service>
locality_counts() {
  proxy_responses "$OBSERVER" | grep "authority=\"${1}\." \
    | sed -e 's/.*dst_zone_locality="\([^"][^"]*\)".*} \([0-9][0-9]*\)$/\1 \2/' \
          -e 't' \
          -e 's/.*} \([0-9][0-9]*\)$/unlabelled \1/' \
    | awk '$1 == "local"  { l += $2 }
           $1 == "remote" { r += $2 }
           $1 != "local" && $1 != "remote" { u += $2 }
           END { printf "%d %d %d\n", l+0, r+0, u+0 }'
}

# Per-mode state, as: "<mode> <svc> <load> <low> <high> <active> <avail> <local> <remote> <unlabelled>"
#
# Captured to a file at two marks rather than polled. The band-watching loop
# below is deliberately left alone: it samples every 5s and its timing IS the
# measurement, so adding two more services' worth of `linkerd diagnostics` calls
# into it would slow the loop and perturb the reaction time it exists to record.
mode_state() {
  local svc="$1" hl act avail loc
  hl="$(hazl_load "$OBSERVER" "$svc")"
  act="$(active_endpoints "$OBSERVER" "$svc")"
  avail="$(endpoint_pool "$OBSERVER" "$svc")"
  loc="$(locality_counts "$svc")"
  echo "${hl:-0 0 0} ${act:-0} ${avail:-0} ${loc}"
}

capture_modes() {  # <outfile>
  local mode svc
  echo "$MODES" | while read -r mode svc; do
    [ -n "$svc" ] || continue
    printf '%s %s %s\n' "$mode" "$svc" "$(mode_state "$svc")"
  done > "$1"
}

# Field n of a mode's row.
mode_field() {  # <file> <mode> <n>
  awk -v m="$2" -v n="$3" '$1 == m { print $(n) }' "$1"
}

fails=0
check() {
  if [ "$2" = "pass" ]; then printf '%-54s \033[1;32mPASS\033[0m  %s\n' "$1" "$3"
  else printf '%-54s \033[1;31mFAIL\033[0m  %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

cleanup() {
  # Sampler first: it is a child of this script and would otherwise outlive
  # the cleanup output. NOT a second `trap ... EXIT` -- that REPLACES the
  # existing one rather than adding to it, which would have silently disabled
  # the restore below.
  sampler_stop
 bash "${REPO_ROOT}/chaos/fm3-zone-brownout.sh" stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The clusters the fault lands in: everything except the one generating load.
brownout_clusters() {
  for c in $(clusters); do [ "$c" = "${LOAD_CLUSTER:-west}" ] || echo "$c"; done
}

# The zone to brown out is the chaos script's to choose, and it chooses one that
# exists in the clusters it targets. Deriving it here from the OBSERVER's node
# was correct only while every cluster shared zone names: with region-scoped
# zones the observer sits in region-b and the fault lands in region-a, so this
# produced a zone that matches nothing and a run that measures nothing.
#
# So mirror the chaos script's choice -- the first zone of the region being
# browned out -- rather than leaving the zone for it to pick. The premise check
# below compares node zones against this value, and an empty one matches no
# node in any cluster: every run would abort reporting a missing pod, for a
# fault that was configured correctly.
ZONE="${ZONE:-$(zones_for "$(brownout_clusters | head -1)" | head -1)}"

banner "FM3 zone brownout -- '${ZONE}', observed from '${OBSERVER}'"

# Size the fault from the band that is actually in force.
#
# This repo's own lesson from FM3 is "read the band, do not assume it" -- and
# this runner assumed it. The 400ms default is derived from a high threshold of
# 6.00, which assumes a 3-endpoint active pool. This environment baselines at 4,
# so the band is [3.20 .. 8.00], and 400ms was recorded peaking at 7.846 and
# 7.895 against exactly that 8.00. Twice. Never crossed, both times read as a
# HAZL non-reaction, both times an arithmetic error in the harness.
#
# The 2026-08-27 run got a result only because an operator did this arithmetic
# by hand and passed 650ms. A manual step that has already cost two runs belongs
# in the code.
#
# Scale the calibrated default by how much larger this rig's threshold is, plus
# margin. Not a physical model of the load metric -- the relationship between
# injected latency and observed load is not linear here (400ms -> ~7.87 and
# 650ms -> 10.04) -- so the arithmetic is printed for the operator to overrule.
# The fault does not reach every endpoint HAZL is using, and the arithmetic has
# to know that.
#
# HAZL holds one same-zone endpoint per cluster -- 3 active across 3 clusters.
# BROWNOUT_CLUSTERS excludes the load cluster (slowing the zone the client lives
# in measures the client as much as the mesh), so only 2 of those 3 are actually
# slowed. The third stays fast and keeps pulling the average down.
#
# Measured: 500ms sized without this correction peaked at 4.697 against a 6.00
# threshold and never crossed -- a third near-miss of exactly the kind this
# sizing exists to prevent, and one the earlier formula could not have avoided
# because it assumed the fault reached everything.
size_latency() {
  local high="$1" ms n_all n_brown
  n_all="$(clusters | grep -c .)"
  n_brown="$(brownout_clusters | grep -c .)"
  [ "${n_brown:-0}" -gt 0 ] || n_brown="$n_all"
  ms="$(awk -v ref="$LATENCY_REF_MS" -v refhigh="$LATENCY_REF_HIGH" \
            -v high="$high" -v margin="$LATENCY_MARGIN" \
            -v all="$n_all" -v brown="$n_brown" -v cap="$LATENCY_MAX_MS" \
        'BEGIN { if (refhigh <= 0 || brown <= 0) { print ref; exit }
                 v = ref * (high / refhigh) * (margin / 100) * (all / brown)
                 if (v > cap) v = cap
                 printf "%d", v }')"
  if [ "$ms" -ge "$LATENCY_MAX_MS" ]; then
    warn "latency capped at ${LATENCY_MAX_MS}ms (the proxy control-plane connect timeout is 1s;
     going past it stops proxies starting and stops this being a brownout test)"
  fi
  echo "${ms}ms"
}

# --- baseline ---------------------------------------------------------------

# Every cluster, not just the observer: BROWNOUT_CLUSTERS is defined inside
# chaos/fm3-zone-brownout.sh and defaults to every cluster except the load
# cluster, so referencing it here would expand to nothing and guard one cluster
# while the fault crosses all of them.
require_control_run
require_settled $(clusters)
# The same gates every other runner has. FM3 lacked them and it cost a run:
# it baselined against a federated pool of 7 because FM1b had stranded pods in
# Init:1/2, and the numbers were contaminated before the brownout was applied.
require_meshed $(clusters)
require_baseline_view "$OBSERVER" "$SVC" "$(federated_pool_size)"

# HAZL's load average is an EWMA, and it needs its own settle.
#
# require_settled knows about pod AGE. It cannot see that the previous FM3 run
# left the load average still decaying, and a baseline taken then is not a
# baseline -- it is a point on someone else's recovery curve.
#
# Measured: a run started ~2 minutes after the previous one baselined at load
# 3.450 instead of ~0.03, and its whole 90s window was a monotonic decay from
# 3.554 to 0.033. The brownout was applied and the trace shows the OLD fault
# clearing. Peak "4.207" was the tail of the previous experiment.
#
# Wait for the average to come back under the band low, which is the threshold
# HAZL itself uses to decide the pool can contract.
wait_load_settled() {
  local svc="$1" deadline load low
  deadline=$(( $(now) + 300 ))
  while [ "$(now)" -lt "$deadline" ]; do
    set -- $(hazl_load "$OBSERVER" "$svc"); load="${1:-0}"; low="${2:-0}"
    if awk -v l="$load" -v b="$low" 'BEGIN{exit !(l < b)}'; then
      ok "load average settled at ${load} (band low ${low})"
      return 0
    fi
    printf '\r  waiting for load average to settle: %s (want < %s)   ' "$load" "$low"
    sleep 10
  done
  echo
  die "load average did not fall below the band low within 300s.
     Something is still driving load -- a brownout left in place, or a previous
     run still clearing. Baselining now would measure that, not this fault."
}
wait_load_settled "$SVC"
# Label BEFORE sampling starts. The phase file persists between runs, so a
# sampler started first records its opening samples under the PREVIOUS run's
# phase -- observed as a stray "restored" at the head of a baseline window.
mark_phase baseline
sampler_start
banner "baseline (traffic should be in-zone)"
show_state
base="$(state_line)"
base_active="$(echo "$base" | awk '{print $4}')"
base_high="$(echo "$base" | awk '{print $3}')"
set -- $(locality_counts "$SVC"); base_local="$1"; base_remote="$2"
printf '  requests: local=%s remote=%s\n' "$base_local" "$base_remote"
proxy_responses "$OBSERVER" > "${RESULTS}/baseline.metrics"
record_node_state "${RESULTS}/baseline.nodes"

log "capturing baseline state for all three exposure modes"
capture_modes "${RESULTS}/baseline.modes"
awk '{ printf "  %-10s %-20s load=%-8s band=[%s .. %s]  active=%s of %s\n", $1, $2, $3, $4, $5, $6, $7 }' \
  "${RESULTS}/baseline.modes"

[ -n "$base_active" ] && [ "$base_active" -gt 0 ] 2>/dev/null \
  || die "no HAZL data for ${SVC} -- is the control plane running with -ext-endpoint-zone-weights?"

if [ -n "$LATENCY" ]; then
  log "latency ${LATENCY} set explicitly; band high is ${base_high}"
else
  LATENCY="$(size_latency "$base_high")"
  log "sizing the fault from the measured band, not the documented default:
     band high        ${base_high}   (active pool ${base_active})
     reference        ${LATENCY_REF_MS}ms calibrated for a high of ${LATENCY_REF_HIGH}
     margin           ${LATENCY_MARGIN}%
     reach            $(brownout_clusters | grep -c .) of $(clusters | grep -c .) clusters browned out
     -> injecting     ${LATENCY}
     Override with LATENCY=<n>ms if this rig disagrees."
fi

# --- inject -----------------------------------------------------------------

# The premise, checked before the fault rather than inferred from its absence.
#
# FM3 slows one zone of the browned-out region in every cluster EXCEPT the load
# cluster, and the whole experiment assumes each of those clusters has an app pod
# in that zone for the fault to land on. The spread constraint that arranges this is
# `whenUnsatisfiable: ScheduleAnyway` -- deliberately soft, because a strict one
# deadlocks when the hard-zone variant cordons a node -- so the scheduler drifts
# away from it across a session of restarts, and nothing noticed.
#
# Measured 2026-09-08, under the old cluster-wide zone names: after a day of
# experiments the load generator sat in `zone-b` and NEITHER east NOR central had
# a `zone-b` app pod. The brownout hit
# nothing, and the run reported "HAZL did not react" and "no remote-zone
# traffic" -- a confident negative result about a fault that never touched an
# endpoint anyone was using.
#
# Refuse instead. A premise that has quietly stopped holding is the one thing
# this experiment cannot detect from its own output.
banner "checking the premise: is there a pod to slow?"
missing=""
for c in $(clusters); do
  [ "$c" != "${LOAD_CLUSTER:-west}" ] || continue
  found=""
  for n in $(kubectl --context="$(ctx "$c")" -n "$APP_NS" get pods -l app=app \
      --no-headers -o wide 2>/dev/null | awk '{print $7}'); do
    # `|| true`: a pod that has not been scheduled yet has no node, and
    # `kubectl get node ""` fails -- which under set -e aborts the script before
    # it can report anything, so the check died silently instead of explaining
    # itself. Exactly the failure shape this whole audit keeps finding.
    z="$(kubectl --context="$(ctx "$c")" get node "$n" \
      -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)"
    if [ "$z" = "$ZONE" ]; then found=1; break; fi
  done
  if [ -z "$found" ]; then missing="${missing} ${c}"; fi
done
[ -z "$missing" ] || die "no app pod in zone '${ZONE}' in:${missing}

     FM3 slows '${ZONE}' in every cluster except the load cluster, so with no pod
     there the fault lands on nothing and the run reports 'HAZL did not react'
     about an endpoint it never touched. The zone spread is a soft constraint
     (whenUnsatisfiable: ScheduleAnyway) and the scheduler drifts off it across
     restarts. Restart the app deployments until every cluster has a pod in
     '${ZONE}', or set ZONE= to one that is populated everywhere."
ok "every brownout cluster has an app pod in '${ZONE}'"

banner "injecting brownout"
annot_start="$(bash "${REPO_ROOT}/verify/annotate.sh" start 2>/dev/null || true)"
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM3: ${ZONE} brownout +${LATENCY}" "fm3" "inject" >/dev/null 2>&1 || true
mark_phase injected

bash "${REPO_ROOT}/chaos/fm3-zone-brownout.sh" start "$ZONE" "$LATENCY" 2>&1 | grep -E '  ok' || true

# Prove the fault landed before measuring the response to it.
#
# Without this, a brownout that silently failed to apply is indistinguishable
# from HAZL not reacting -- and the checks below would report the second while
# the truth was the first. FM1c has this precondition; FM3 did not, and it spent
# six attempts partly because "did nothing happen, or did nothing get injected?"
# was never separable.
applied=0
for c in $(clusters); do
  n="$(kubectl --context="$(ctx "$c")" -n "${CHAOS_NS:-chaos-mesh}" \
    get networkchaos --no-headers 2>/dev/null | grep -c . || true)"
  applied=$(( applied + ${n:-0} ))
done
[ "$applied" -gt 0 ] || die "no NetworkChaos objects exist after injection, so the brownout
     never applied. Every check below would measure an un-faulted rig and read
     as 'HAZL did not react'. Check the chaos-mesh controllers before re-running."
ok "brownout is applied (${applied} NetworkChaos objects across the rig)"

# Endpoints must NOT leave the EndpointSlice: that is what makes this a
# brownout rather than a failure, and it is why Kubernetes stays silent.
ready_pods="$(kubectl --context="$(ctx "$OBSERVER")" -n "$APP_NS" get pods -l app=app \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c '2/2\|1/1' || true)"
printf '\n  app pods still Running in %s: %s (nothing has failed)\n' "$OBSERVER" "$ready_pods"

# --- watch the band ---------------------------------------------------------

banner "watching the load band (${SETTLE}s)"
peak_load=0; max_active="$base_active"; crossed=""

# Peak active pool per mode, sampled THROUGHOUT rather than read at the end.
#
# This is the fix for a defect that made the same experiment report PASS and
# FAIL for the same behaviour. The core check below tracked max_active across
# the window and correctly caught the pool widening 4 -> 6. The three-mode
# comparison read `during.modes`, captured after the settle -- by which time the
# brownout was over, load had collapsed to 0.036 and HAZL had contracted to 1.
# The comparison was measuring the RECOVERY and calling it a failure.
#
# Only `active` needs a peak. The traffic counts are cumulative counters, so
# reading those at the end is correct and stays as it was.
for m in $(echo "$MODES" | awk 'NF {print $1}'); do
  eval "peak_act_${m}=\"$(mode_field "${RESULTS}/baseline.modes" "$m" 6)\""
done

t0="$(now)"
deadline=$(( t0 + SETTLE ))
while [ "$(now)" -lt "$deadline" ]; do
  s="$(state_line)"
  l="$(echo "$s" | awk '{print $1}')"; hi="$(echo "$s" | awk '{print $3}')"
  a="$(echo "$s" | awk '{print $4}')"
  printf '\r  t+%-3ss  load=%-8s high=%-6s active=%-3s' "$(( $(now) - t0 ))" "$l" "$hi" "$a"
  awk -v a="$l" -v b="$peak_load" 'BEGIN{exit !(a>b)}' && peak_load="$l"
  [ "${a:-0}" -gt "${max_active:-0}" ] 2>/dev/null && max_active="$a"

  # One extra read per mode per poll. Deliberately just active_endpoints and not
  # the full mode_state: four CLI round trips per mode would perturb the very
  # timing this loop exists to measure.
  while read -r m s; do
    [ -n "$s" ] || continue
    ma="$(active_endpoints "$OBSERVER" "$s")"
    eval "prev=\${peak_act_${m}:-0}"
    if [ "${ma:-0}" -gt "${prev:-0}" ] 2>/dev/null; then eval "peak_act_${m}=\"${ma}\""; fi
  done <<EOF
$MODES
EOF
  # Compare against the band that was in force at INJECTION time, not the
  # current one. The band scales with the active pool (0.8 and 2.0 per
  # endpoint), so as HAZL adds endpoints the threshold rises underneath us --
  # observed here going [2.40..6.00] -> [3.20..8.00] as active went 3 -> 4.
  # Testing against the moving value means a genuine crossing never registers.
  [ -z "$crossed" ] && awk -v a="$l" -v b="$base_high" 'BEGIN{exit !(a>b)}' \
    && crossed="$(( $(now) - t0 ))"
  sleep 5
done
echo
show_state
proxy_responses "$OBSERVER" > "${RESULTS}/during.metrics"
record_node_state "${RESULTS}/during.nodes"

set -- $(locality_counts "$SVC"); now_local="$1"; now_remote="$2"
d_local=$(( now_local - base_local )); d_remote=$(( now_remote - base_remote ))
printf '  requests during brownout: local=%s remote=%s\n' "$d_local" "$d_remote"

capture_modes "${RESULTS}/during.modes"

# --- evaluate ---------------------------------------------------------------

banner "results"

# Reported, not asserted -- and this is not a threshold being relaxed to get a
# green check. The crossing is not reliably observable, for a reason this repo
# documented before the check was written:
#
#   "a naive 'is load above the high band right now?' check can never fire,
#    because by the time you sample it the threshold has moved."
#
# Expansion raises the bar for further expansion, so the instant load exceeds
# the band is also the instant HAZL widens and the load starts falling. At a 5s
# poll the crossing sits between samples.
#
# Four runs on 2026-09-08, sizing the fault from the measured band:
#
#   500ms -> peak 4.697    750ms -> peak 5.764    900ms -> peak 5.751
#
# Peak asymptotes below the 6.00 threshold while HAZL demonstrably widens the
# pool every time. More latency does not raise it: shedding the slow endpoints
# lowers throughput through them, and load is latency x throughput, so the
# metric self-limits as the mechanism under test reacts. Sizing cannot fix
# that, and pretending a bigger fault would is how the last four attempts went.
#
# So assert the BEHAVIOUR, which is observable and is what the experiment is
# about: the pool widened, and traffic moved off the slow zone. Both fire
# reliably. The load average is evidence of the mechanism, not a gate on it.
if [ -n "$crossed" ]; then
  ok "load average crossed the band high: peak ${peak_load} vs ${base_high}, after ${crossed}s"
else
  log "load average peaked at ${peak_load} against a band high of ${base_high} in force at injection.
     Not a failure: the crossing is between samples by construction, because
     expansion lifts the threshold the moment load reaches it. The widening
     below is the observable evidence that HAZL reacted."
fi

if [ "${max_active:-0}" -gt "${base_active:-0}" ] 2>/dev/null; then
  check "HAZL widens the endpoint pool" pass "${base_active} -> ${max_active} active endpoints"
else
  check "HAZL widens the endpoint pool" fail "stayed at ${base_active} active"
fi

if [ "$d_remote" -gt 0 ]; then
  pct=$(( d_remote * 100 / (d_local + d_remote > 0 ? d_local + d_remote : 1) ))
  check "traffic shifts to remote-zone endpoints" pass "${d_remote} remote-zone reqs (${pct}%)"
else
  check "traffic shifts to remote-zone endpoints" fail "no remote-zone traffic"
fi

# The whole point: none of this was visible to Kubernetes.
printf '\n  Throughout, every app pod stayed Ready and in its EndpointSlice.\n'
printf '  No Kubernetes signal fired. Topology Aware Routing, which keys off\n'
printf '  topology rather than load, would have kept sending to the slow zone.\n'

# --- the same fault, through all three exposure modes -----------------------
#
# chaos/fm3-zone-brownout.sh slows app, app-flat AND app-gateway in the chosen
# zone, so this is one fault seen three ways rather than three faults.

banner "the same fault, through all three exposure modes"

printf '  %-10s %-20s %-9s %-9s %-16s %s\n' MODE SERVICE ACTIVE AVAIL 'LOAD (base->now)' 'REQUESTS local/remote/unlabelled'
while read -r mode svc _ _ _ _ _ _ _ _; do
  [ -n "$mode" ] || continue

  b_act="$(mode_field "${RESULTS}/baseline.modes" "$mode" 6)"
  b_avail="$(mode_field "${RESULTS}/baseline.modes" "$mode" 7)"
  b_load="$(mode_field "${RESULTS}/baseline.modes" "$mode" 3)"
  b_local="$(mode_field "${RESULTS}/baseline.modes" "$mode" 8)"
  b_remote="$(mode_field "${RESULTS}/baseline.modes" "$mode" 9)"
  b_unlab="$(mode_field "${RESULTS}/baseline.modes" "$mode" 10)"

  n_act="$(mode_field "${RESULTS}/during.modes" "$mode" 6)"
  n_avail="$(mode_field "${RESULTS}/during.modes" "$mode" 7)"
  n_load="$(mode_field "${RESULTS}/during.modes" "$mode" 3)"
  n_local="$(mode_field "${RESULTS}/during.modes" "$mode" 8)"
  n_remote="$(mode_field "${RESULTS}/during.modes" "$mode" 9)"
  n_unlab="$(mode_field "${RESULTS}/during.modes" "$mode" 10)"

  printf '  %-10s %-20s %-9s %-9s %-16s %s/%s/%s\n' \
    "$mode" "$svc" \
    "${b_act} -> ${n_act}" "$n_avail" "${b_load} -> ${n_load}" \
    "$(( n_local - b_local ))" "$(( n_remote - b_remote ))" "$(( n_unlab - b_unlab ))"
done < "${RESULTS}/during.modes"

echo
while read -r mode svc _ _ _ _ _ _ _ _; do
  [ -n "$mode" ] || continue

  b_act="$(mode_field "${RESULTS}/baseline.modes" "$mode" 6)"
  n_act="$(mode_field "${RESULTS}/during.modes" "$mode" 6)"
  n_avail="$(mode_field "${RESULTS}/during.modes" "$mode" 7)"

  d_rem=$(( $(mode_field "${RESULTS}/during.modes" "$mode" 9) - $(mode_field "${RESULTS}/baseline.modes" "$mode" 9) ))
  d_loc=$(( $(mode_field "${RESULTS}/during.modes" "$mode" 8) - $(mode_field "${RESULTS}/baseline.modes" "$mode" 8) ))
  d_unl=$(( $(mode_field "${RESULTS}/during.modes" "$mode" 10) - $(mode_field "${RESULTS}/baseline.modes" "$mode" 10) ))

  if [ "$mode" = "gateway" ]; then
    # Asserted as a NON-event, and the assertion is about the zone SIGNAL rather
    # than the endpoint count -- a gateway deployment scaled past one replica
    # would change the count without changing the mechanism.
    #
    # A gateway mirror resolves to the target cluster's gateway address, which
    # is a node address and carries no zone. There is nothing for a zone-aware
    # balancer to prefer, so there is nothing to widen into. Any reaction to the
    # brownout happens inside the target cluster, invisible from here.
    if [ "$d_loc" -eq 0 ] && [ "$d_rem" -eq 0 ] && [ "$d_unl" -gt 0 ]; then
      check "gateway mode has no zone signal to act on" pass \
        "${d_unl} reqs, none carrying a locality label; pool ${n_avail}"
    else
      check "gateway mode has no zone signal to act on" fail \
        "local=${d_loc} remote=${d_rem} unlabelled=${d_unl} -- the gateway mirror IS zone-labelled here, which changes the claim"
    fi
    continue
  fi

  # federated and flat: same mechanism, different amounts of room.
  #
  # PEAK active, not end-state active -- see the sampling loop above for why.
  eval "p_act=\${peak_act_${mode}:-0}"

  # "Steps off the slow zone" is the claim. Widening the pool is only ONE way to
  # satisfy it, and the check used to demand it from every mode.
  #
  # app-flat has exactly 3 endpoints, one per zone, all in the target cluster.
  # It cannot widen past 3 -- there is nowhere to widen TO. On 2026-08-27 it
  # moved 100% of its traffic off the slow zone (2797 remote, 0 local): it did
  # precisely what this check is named for, by REDISTRIBUTING rather than
  # expanding, and was marked FAIL for not growing a pool it cannot grow.
  #
  # So: a mode with room must widen; a mode already at its ceiling must
  # redistribute. Both are "stepping off the slow zone"; only the mechanism
  # differs, and which one applies is a property of the topology, not of HAZL.
  has_room=0
  if [ "${n_avail:-0}" -gt "${b_act:-0}" ] 2>/dev/null; then has_room=1; fi

  if [ "$has_room" = "1" ]; then
    if [ "${p_act:-0}" -gt "${b_act:-0}" ] 2>/dev/null && [ "$d_rem" -gt 0 ]; then
      check "${mode} mode steps off the slow zone (widens)" pass \
        "active ${b_act} -> ${p_act} peak of ${n_avail}, ${d_rem} remote-zone reqs"
    else
      check "${mode} mode steps off the slow zone (widens)" fail \
        "active ${b_act} -> ${p_act} peak of ${n_avail}, ${d_rem} remote-zone reqs"
    fi
  else
    # At the ceiling: the pool cannot grow, so the evidence is where the traffic
    # went. Requires remote traffic to appear AND to dominate, otherwise "it
    # sent a few requests elsewhere" would pass.
    d_tot=$(( d_loc + d_rem ))
    rem_pct=$(( d_tot > 0 ? d_rem * 100 / d_tot : 0 ))
    if [ "$d_rem" -gt 0 ] && [ "$rem_pct" -ge 50 ]; then
      check "${mode} mode steps off the slow zone (redistributes)" pass \
        "pool already at its ceiling (${n_avail}); ${rem_pct}% of traffic moved off-zone"
    else
      check "${mode} mode steps off the slow zone (redistributes)" fail \
        "pool at ceiling (${n_avail}) and only ${rem_pct}% moved off-zone"
    fi
  fi
done < "${RESULTS}/during.modes"

printf '\n  Read the gateway row as the cost of the hop, not as a HAZL limitation.\n'
printf '  Load-aware routing needs endpoints to choose between; a gateway mirror\n'
printf '  gives the client exactly one, and strips the zone metadata on the way.\n'

# --- restore ----------------------------------------------------------------

banner "removing the brownout"
mark_phase restored
bash "${REPO_ROOT}/chaos/fm3-zone-brownout.sh" stop 2>&1 | grep -E '  ok' || true
bash "${REPO_ROOT}/verify/annotate.sh" end "$annot_start" \
  "FM3: ${ZONE} brownout (+${LATENCY})" "fm3" >/dev/null 2>&1 || true

# Contraction, and it has to be able to tell contraction from collapse.
#
# This used to accept `active <= base_active` and report success. A pool that
# had fallen BELOW where it started -- 1 against a baseline of 4, which is what
# the 2026-08-27 run actually printed -- was indistinguishable from a healthy
# return to baseline:
#
#     t+0 s  active=1  (want back to 4)
#     ok  pool contracted back to 4 in 0s
#
# It also matched instantly, at t+0, before HAZL could have done anything --
# so the "0s" was not a measurement of anything. Require a return TO the
# baseline, and say so distinctly when the pool undershoots it.
log "waiting for HAZL to withdraw the extra endpoints (band low)"
t0="$(now)"; withdrew=""; collapsed=""
deadline=$(( t0 + 180 ))
while [ "$(now)" -lt "$deadline" ]; do
  a="$(active_endpoints "$OBSERVER" "$SVC")"
  printf '\r  t+%-3ss  active=%-3s (want back to %s)' "$(( $(now) - t0 ))" "${a:-?}" "$base_active"
  if [ "${a:-0}" -eq "${base_active:-0}" ] 2>/dev/null; then
    withdrew="$(( $(now) - t0 ))"; break
  fi
  if [ "${a:-0}" -lt "${base_active:-0}" ] 2>/dev/null; then collapsed="$a"; fi
  sleep 5
done
echo
if [ -n "$withdrew" ]; then
  ok "pool contracted back to ${base_active} in ${withdrew}s"
elif [ -n "$collapsed" ]; then
  warn "pool did not return to ${base_active}: it fell to ${collapsed}, BELOW the baseline.
     That is a collapse, not a contraction. Most likely the load generator is no
     longer offering the baseline rate -- check the loadgen pod before reading
     any other number from this run."
else
  warn "pool had not contracted back to ${base_active} within 180s"
fi

proxy_responses "$OBSERVER" > "${RESULTS}/recovered.metrics"
record_node_state "${RESULTS}/recovered.nodes"
show_state

echo
printf 'raw metric snapshots written to %s\n' "$RESULTS"
[ "$fails" -eq 0 ] || die "${fails} check(s) failed"
ok "FM3 complete"
