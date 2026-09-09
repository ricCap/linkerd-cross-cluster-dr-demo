#!/usr/bin/env bash
# FM1 experiment runner: control plane failure.
#
#   verify/fm1-verify.sh destination
#   verify/fm1-verify.sh identity
#
# Unlike FM2 and FM4 this does not kill any workload. Every pod keeps running
# and every dashboard stays green. The question is what the mesh can no longer
# DO -- which is the part DR plans never test, because nothing looks broken.
#
# destination:
#   Discovery is frozen. Existing traffic flows on cached endpoints. Then we
#   remove endpoints in another cluster and measure whether failover happens.
#   Expectation: it does not, because nothing can tell the proxies the
#   endpoints went away. "The mesh is fine" and "the mesh cannot react" are
#   simultaneously true.
#
#   All three exposure modes are removed together, because the freeze should
#   NOT affect them equally and the difference is the finding. Federated and
#   flat membership are resolved by the frozen destination controller in this
#   cluster. A gateway mirror's endpoint is the target cluster's gateway
#   address -- maintained by the service-mirror controller, and stable -- while
#   the actual backend choice happens inside the target cluster, whose control
#   plane is fine. So the hypothesis is that gateway mode still SEES the
#   change, and reports it as 5xx, while the other two stay silently stale.
#
#   If that holds it inverts FM2 and FM4, where gateway mode is the worst
#   performer: pushing discovery into the target cluster trades a silent
#   staleness for a loud failure.
#
# identity:
#   Existing proxies keep their certificates and keep working. But no NEW pod
#   can get one. We measure the real survival window from the certificates
#   themselves, then prove the consequence that actually matters: a scale-up --
#   which every failover plan assumes -- cannot complete.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need linkerd kubectl

MODE="${1:-}"
TARGET="${TARGET:-central}"  # cluster whose control plane we break
PEER="${PEER:-east}"         # cluster whose endpoints we remove, for the destination test
SETTLE="${SETTLE:-90}"
RPS="${RPS:-30}"

case "$MODE" in destination|identity|mirror) ;; *) die "usage: fm1-verify.sh <destination|identity|mirror>";; esac

# Namespaced by PROFILE. Both arms used to write here, so running the second
# sweep destroyed the first one's raw snapshots -- Arm B overwrote Arm A on
# 2026-09-08 and only the SUMMARY files and TSDB archives survived.
RESULTS="${REPO_ROOT}/results/${PROFILE:-default}/fm1-${MODE}"
local_cp_ok=n/a
mkdir -p "$RESULTS"

# Record WHICH cluster these snapshots were taken from.
#
# The runners do not agree on this and should not have to: FM1 reads the proxy
# in the cluster whose control plane it breaks, the others read a surviving
# observer. Anything replaying the snapshots later cannot tell from the files,
# and picking wrong is silent -- the mirror service names differ per cluster, so
# the wrong observer measures a service that was never exercised and reports it
# as zero traffic.
echo "$TARGET" > "${RESULTS}/observer"
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
CTX="$(ctx "$TARGET")"

# FM1 needs a client INSIDE the cluster whose control plane it breaks.
#
# A stale endpoint pool is a property of one proxy: west's view of
# app-federated is maintained by west's own destination controller, so a
# west client cannot see central's discovery freeze no matter how long it runs.
# Every other experiment measures from a surviving observer; this one cannot.
#
# Steady-state load now runs in west alone (see clusters/08-load.sh for why), so
# bring a generator up here for the duration and take it away afterwards. The
# alternative -- leaving a permanent generator in central -- reintroduces exactly
# the co-location that made "the survivors absorbed the traffic" untestable.
TEMP_LOADGEN=0
if ! kubectl --context="$CTX" -n "$APP_NS" get deploy loadgen >/dev/null 2>&1; then
  log "no load generator in '${TARGET}' -- starting one for this run"
  LOAD_CLUSTERS="$TARGET" bash "${REPO_ROOT}/clusters/08-load.sh" start steady >/dev/null 2>&1 \
    || die "could not start a load generator in '${TARGET}'"
  TEMP_LOADGEN=1
  log "  waiting for it to produce traffic"
  sleep 20
fi

# The measurement surface is the BROKEN cluster's own load generator: the
# question is what this cluster can no longer do, so it has to be the one
# watching. modes_for tells us which mirrors it can actually resolve --
# central sources a gateway link precisely so this experiment has all three.
MODES="$(modes_for "$TARGET")"

mode_svc() { echo "$MODES" | awk -v m="$1" '$1 == m { print $2 }'; }

FED_SVC="$(mode_svc federated)"
FLAT_SVC="$(mode_svc flat)"
GW_SVC="$(mode_svc gateway)"

# Which cluster a mirror's backends actually live in, read off the mirror's own
# name rather than assumed from $PEER:
#
#   app-flat-east          -> east
#   app-gateway-east-gw -> east
#
# $PEER is only meaningful for the federated service, which is a union and so
# has a member in every cluster. Tying the other two to $PEER as well looks
# right until someone overrides it, at which point the script scales down a
# deployment in one cluster and measures a mirror pointing at another -- and
# reports "no change", which is indistinguishable from a real negative result.
mirror_cluster() { local n="${1%-gw}"; echo "${n##*-}"; }

FLAT_CLUSTER="$(mirror_cluster "$FLAT_SVC")"
GW_CLUSTER="$(mirror_cluster "$GW_SVC")"

[ -n "$GW_SVC" ] || die "'${TARGET}' resolves no gateway mirror, so this experiment
would compare two modes out of three and say nothing about it. Add '${TARGET}:<target>'
to GATEWAY_LINKS in clusters/05-multicluster.sh and rebuild, or set TARGET to a
cluster that sources one."

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Every snapshot records WHEN it was taken. The throughput denominator has to
# be real elapsed time between two snapshots, never a nominal window -- see the
# `expected` calculation in the identity arm for what that cost last time.
snapshot() {
  local label="$1" metrics mode svc t
  eval "t_${label}=\"$(now)\""
  metrics="$(proxy_responses "$TARGET")"
  echo "$metrics" > "${RESULTS}/${label}.metrics"
  record_node_state "${RESULTS}/${label}.nodes"

  printf '\n[%s]  pool(%s)=%s\n' "$label" "$FED_SVC" "$(endpoint_pool "$TARGET" "$FED_SVC")"
  echo "$MODES" | while read -r mode svc; do
    [ -n "$svc" ] || continue
    t="$(mode_totals "$metrics" "$svc")"
    # shellcheck disable=SC2086
    printf '  %-10s %-20s total=%-8s errors=%-8s non-mTLS=%s\n' "$mode" "$svc" $t
  done
}

# Requests and errors for one mode BETWEEN two snapshots.
#   mode_delta <before.metrics> <after.metrics> <svc> <1=total|2=errors>
#
# Guarded, like FM2's and FM4's: a proxy counter that went backwards means the
# loadgen pod restarted mid-run -- and the loadgen IS the instrument -- so every
# number from this window is meaningless. counter_delta refuses rather than
# handing a negative straight into a percentage and a PASS/FAIL.
mode_delta() {
  local b a
  # Per-series. Summing each snapshot and subtracting discards traffic served
  # by endpoints the fault removed -- see mode_totals_delta in verify/lib.sh.
  mode_totals_delta "$1" "$2" "$3" | awk -v f="$4" '{print $f}'
}

fails=0
check() {
  if [ "$2" = "pass" ]; then printf '%-52s \033[1;32mPASS\033[0m  %s\n' "$1" "$3"
  else printf '%-52s \033[1;31mFAIL\033[0m  %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

cleanup() {
  # Sampler first: it is a child of this script and would otherwise outlive
  # the cleanup output. NOT a second `trap ... EXIT` -- that REPLACES the
  # existing one rather than adding to it, which would have silently disabled
  # the restore below.
  sampler_stop

  banner "restoring"
  if [ "${TEMP_LOADGEN:-0}" = "1" ]; then
    log "removing the temporary load generator from '${TARGET}'"
    kubectl --context="$CTX" -n "$APP_NS" delete deploy loadgen --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context="$CTX" -n "$APP_NS" delete cm loadgen-scripts --ignore-not-found >/dev/null 2>&1 || true
  fi
  bash "${REPO_ROOT}/chaos/fm1-control-plane.sh" restore "$TARGET" 2>&1 | grep -E '  ok|warn' || true
  # Every deployment the destination variant scales to 0 has to come back, in
  # the cluster it was scaled down in -- same derivation as the scale-down, so
  # the two cannot drift. Missing one leaves the next experiment failing its
  # 9-endpoint precondition for no visible reason.
  kubectl --context="$(ctx "$PEER")" -n "$APP_NS" scale deploy app --replicas=3 >/dev/null 2>&1 || true
  kubectl --context="$(ctx "$FLAT_CLUSTER")" -n "$APP_NS" scale deploy app-flat --replicas=3 >/dev/null 2>&1 || true
  kubectl --context="$(ctx "$GW_CLUSTER")" -n "$APP_NS" scale deploy app-gateway --replicas=3 >/dev/null 2>&1 || true
  kubectl --context="$CTX" -n "$APP_NS" scale deploy app --replicas=3 >/dev/null 2>&1 || true

  # Delete pods this experiment stranded, rather than only fixing the replica
  # count.
  #
  # FM1b scales app 3 -> 6 with identity down. The new pods never leave
  # Init:1/2, because the proxy is a native sidecar init container that cannot
  # get a certificate -- that IS the finding. Scaling back to 3 lets the
  # ReplicaSet keep a stranded pod as one of its three, so the deployment
  # reports 3 replicas while only 2 are serving.
  #
  # Nothing surfaces that. The pool silently reads 8 of 9, and the NEXT
  # experiment inherits it: FM3 ran against AVAIL 7 and its numbers were
  # contaminated before it started. A cleanup that restores a count without
  # restoring capacity is the same class of bug as the restore that put back
  # one replica of three.
  for c in "$CTX" "$(ctx "$PEER")" "$(ctx "$FLAT_CLUSTER")" "$(ctx "$GW_CLUSTER")"; do
    stranded="$(kubectl --context="$c" -n "$APP_NS" get pods -o json 2>/dev/null \
      | jq -r '.items[]
               | select(.status.phase == "Pending" or ((.status.containerStatuses // []) | length) == 0)
               | .metadata.name' 2>/dev/null || true)"
    for p in $stranded; do
      kubectl --context="$c" -n "$APP_NS" delete pod "$p" --force --grace-period=0 >/dev/null 2>&1 || true
      warn "  removed stranded pod ${p} (never got a proxy, would have degraded the pool)"
    done
  done

  bash "${REPO_ROOT}/verify/annotate.sh" point "FM1 ${MODE}: restored" "fm1" "restore" >/dev/null 2>&1 || true
  mark_phase restored
}
trap cleanup EXIT

banner "FM1 ${MODE} -- breaking the control plane in '${TARGET}'"

# Every cluster this experiment touches: the one whose control plane breaks, the
# one whose backends are scaled away, and the two the non-federated modes are
# pinned to. Guarding only TARGET watched the cluster where nothing moves.
require_control_run
require_settled "$TARGET" "$PEER" "$FLAT_CLUSTER" "$GW_CLUSTER"
require_meshed $(clusters)
require_baseline_view "$TARGET" "$FED_SVC" "$(federated_pool_size)"

# Which instrument answers "did this cluster learn?" depends on WHICH component
# the experiment breaks, and getting this wrong produced a vacuous pass.
#
#   destination (FM1a)  scales linkerd-destination to zero. Asking destination
#                       anything then returns nothing, and comparing nothing to
#                       nothing passes every time. The proxy's cached view is
#                       the only view left, and it is also the one under test --
#                       the finding is that the proxy still believes in nine
#                       endpoints when three are gone.
#   mirror (FM1c)       leaves destination running, so ask it directly. It is
#                       the authoritative answer and does not depend on the
#                       balancer's opinion.
if [ "$MODE" = "destination" ]; then
  view_of() { proxy_endpoint_view "$1" "$2"; }
  view_src="proxy"
else
  view_of() { destination_endpoints "$1" "$2"; }
  view_src="destination"
fi

# BEFORE injection. It used to be captured after, so FM1a recorded a baseline
# taken from a controller that had already been scaled to zero.
pool_before="$(view_of "$TARGET" "$FED_SVC")"

# An empty or wrong reading here makes the freeze check vacuous rather than
# false: it would compare nothing to nothing and pass. Refuse instead. This is
# the guard that would have caught the run where FM1a asked a destination
# controller it had already scaled to zero.
[ -n "$pool_before" ] && [ "$pool_before" = "$(federated_pool_size)" ] 2>/dev/null || die \
  "the ${view_src} view of ${FED_SVC} reads '${pool_before:-empty}', expected $(federated_pool_size).
     The freeze check compares this against the same reading after the fault, so
     starting from an unusable value would make it pass without measuring
     anything. Fix the baseline before injecting."
# Label BEFORE sampling starts. The phase file persists between runs, so a
# sampler started first records its opening samples under the PREVIOUS run's
# phase -- observed as a stray "restored" at the head of a baseline window.
mark_phase baseline
sampler_start
snapshot baseline

annot_start="$(bash "${REPO_ROOT}/verify/annotate.sh" start 2>/dev/null || true)"
bash "${REPO_ROOT}/verify/annotate.sh" point \
  "FM1 ${MODE}: control plane down in ${TARGET}" "fm1" "inject" >/dev/null 2>&1 || true
mark_phase injected

if [ "$MODE" = "destination" ] || [ "$MODE" = "mirror" ]; then
  # ------------------------------------------------- destination / mirror
  #
  # One branch, deliberately. Both break a discovery component and then apply
  # the IDENTICAL downstream fault -- the backends behind all three exposure
  # modes are removed in the peer cluster. That is what makes the two arms
  # comparable: same event, two different components broken, and the difference
  # in what the cluster can still see is the whole finding.
  #
  #   destination  the proxy's entire view freezes, local and remote alike
  #   mirror       destination is healthy and keeps learning about local change;
  #                what stops is the maintenance of CROSS-CLUSTER membership
  if [ "$MODE" = "mirror" ]; then
    bash "${REPO_ROOT}/chaos/fm1-control-plane.sh" mirror-down "$TARGET" 2>&1 | grep -E '  ok' || true
  else
    bash "${REPO_ROOT}/chaos/fm1-control-plane.sh" destination-down "$TARGET" 2>&1 | grep -E '  ok' || true
  fi
  sleep 15

  # FM1c only: prove this is a DIFFERENT fault from FM1a rather than a
  # differently-named one. If destination were also down, every result below
  # would just be FM1a again -- and it would look like a valid FM1c run.
  if [ "$MODE" = "mirror" ]; then
    dest_ready="$(kubectl --context="$CTX" -n linkerd get deploy linkerd-destination \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    mirrors_up="$(kubectl --context="$CTX" -n linkerd-multicluster get deploy \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
      | awk '/^(controller-|linkerd-local-service-mirror )/ && $2 > 0' | wc -l | tr -d ' ')"
    if [ "${dest_ready:-0}" -gt 0 ] && [ "${mirrors_up:-0}" -eq 0 ]; then
      local_cp_ok=yes
    else
      local_cp_ok=no
    fi
    log "local control plane: destination ready=${dest_ready}, mirror controllers up=${mirrors_up}"
  fi

  banner "removing backends behind ALL THREE modes while discovery is frozen"

  log "scaling ${PEER}/app to 0 -- 3 of the 9 federated endpoints should vanish"
  kubectl --context="$(ctx "$PEER")" -n "$APP_NS" scale deploy app --replicas=0 >/dev/null
  log "scaling ${FLAT_CLUSTER}/api to 0 -- the flat mirror ${FLAT_SVC} loses its backends"
  kubectl --context="$(ctx "$FLAT_CLUSTER")" -n "$APP_NS" scale deploy app-flat --replicas=0 >/dev/null
  log "scaling ${GW_CLUSTER}/app-gateway to 0 -- the gateway mirror ${GW_SVC} loses its backends"
  kubectl --context="$(ctx "$GW_CLUSTER")" -n "$APP_NS" scale deploy app-gateway --replicas=0 >/dev/null

  # Ask the DESTINATION CONTROLLER what it thinks the endpoints are -- not the
  # balancer. See destination_endpoints in verify/lib.sh.
  #
  # This used to read endpoint_pool, which is adaptive_endpoints under BEL and
  # is not a membership signal. On 2026-09-07 it twitched 9 -> 8 at t+0 and the
  # loop below broke on it, collapsing the measurement window from 90s to 17s --
  # so the three exposure modes were then measured over seventeen seconds taken
  # moments after their backends were scaled away, and the flat mirror's "96%"
  # meant "has not collapsed YET" rather than "did not collapse".
  #
  # Hence the second change: RECORD when the view moved, never break on it. The
  # window is what every other check in this run is computed over, and letting a
  # detection event truncate it means one unreliable reading silently invalidates
  # everything else.
  dest_before="$pool_before"
  log "watching whether ${TARGET} notices via its ${view_src} view (${SETTLE}s, holding the full window)"
  noticed=""
  t0="$(now)"
  deadline=$(( t0 + SETTLE ))
  while [ "$(now)" -lt "$deadline" ]; do
    d="$(view_of "$TARGET" "$FED_SVC")"
    printf '\r  t+%-3ss  %s view in %s = %-4s (was %s)  ' \
      "$(( $(now) - t0 ))" "$view_src" "$TARGET" "${d:-?}" "$dest_before"
    if [ -z "$noticed" ] && [ -n "$d" ] && [ "$d" -lt "${dest_before:-9}" ] 2>/dev/null; then
      noticed="$(( $(now) - t0 ))"
    fi
    sleep 5
  done
  echo
  dest_after="$(view_of "$TARGET" "$FED_SVC")"
  printf '  %s view: %s -> %s   (active subset, for reference: %s)\n' \
    "$view_src" "$dest_before" "$dest_after" "$(active_endpoints "$TARGET" "$FED_SVC")"
  snapshot during

  banner "results"

  # FM1c's precondition, checked first: every number below is only about the
  # service-mirror controllers if destination was genuinely still up. A run
  # where both were down is just FM1a wearing FM1c's name, and would otherwise
  # pass every remaining check.
  if [ "$MODE" = "mirror" ]; then
    if [ "$local_cp_ok" = "yes" ]; then
      check "the LOCAL control plane is untouched" pass \
        "destination still serving; only the mirror controllers are down"
    else
      check "the LOCAL control plane is untouched" fail \
        "this is not FM1c -- see the readiness line above"
    fi
  fi

  # FM1c does NOT assert that membership freezes, because two runs say it does
  # not. With all four cross-cluster control plane components down -- every
  # controller-* plus linkerd-local-service-mirror -- central's destination view
  # still tracked the backends going away.
  #
  # The mechanism, checked on the live rig: app-federated has NO EndpointSlices
  # in central at all. Federated membership is resolved by destination across
  # the Links at request time; the mirror controllers own the Service OBJECTS,
  # not a cached copy of the endpoints behind them. So killing them stops new
  # services being mirrored and does not freeze the endpoints of ones already
  # mirrored.
  #
  # That is a better finding than the hypothesis it replaces, and it is reported
  # rather than asserted: nobody has established what SHOULD happen here, so a
  # pass/fail check would be encoding a guess. FM1a keeps its assertion, because
  # a frozen destination controller genuinely does freeze the view and that is
  # measured.
  if [ "$MODE" = "mirror" ]; then
    printf '\n  cross-cluster membership: destination view %s -> %s%s\n' \
      "$dest_before" "$dest_after" \
      "$([ -n "$noticed" ] && echo " (moved after ${noticed}s)" || echo " (never moved)")"
    printf '  Reported, not asserted. app-federated has no EndpointSlices here:\n'
    printf '  destination resolves federated members across the Links directly, so\n'
    printf '  the mirror controllers owning the Service objects is not the same as\n'
    printf '  them owning its endpoints. See results/FINDINGS.md.\n'
  else
    if [ -z "$noticed" ]; then
      check "discovery is frozen (endpoints NOT updated)" pass \
        "${view_src} still reports ${dest_after} of ${dest_before} after ${SETTLE}s, 3 backends gone"
    else
      check "discovery is frozen (endpoints NOT updated)" fail \
        "${view_src} view ${dest_before} -> ${dest_after} after ${noticed}s -- still live"
    fi
  fi

    if [ -z "$noticed" ]; then
      printf '\n  The mesh kept serving and never learned that a third of its\n'
      printf '  federated backends had disappeared. Nothing alerted. Failover to\n'
      printf '  the remaining clusters cannot happen, because from this cluster'"'"'s\n'
      printf '  point of view there is nothing to fail over from.\n'
    fi

  # --- the three-mode contrast ----------------------------------------------
  #
  # Report throughput as well as errors, and for the reason FM2 documents at
  # length: a request with no endpoints sits in the balancer queue and never
  # completes, so it never increments response_total. Errors alone cannot tell
  # "serving fine" apart from "hung". Throughput can.
  banner "what each exposure mode did about it"

  fed_err="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" 2)"
  flat_err="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC" 2)"
  gw_err="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC" 2)"
  fed_tp="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" 1)"
  flat_tp="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC" 1)"
  gw_tp="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC" 1)"

  d_elapsed=$(( t_during - t_baseline ))
  d_expected=$(( RPS * d_elapsed ))
  d_pct() { echo $(( $1 * 100 / (d_expected > 0 ? d_expected : 1) )); }

  printf '\n  over %ss, ~%s expected per mode:\n' "$d_elapsed" "$d_expected"
  printf '  %-10s %-20s %6s reqs (%3s%%)  %6s errors\n' federated "$FED_SVC"  "$fed_tp"  "$(d_pct "$fed_tp")"  "$fed_err"
  printf '  %-10s %-20s %6s reqs (%3s%%)  %6s errors\n' flat      "$FLAT_SVC" "$flat_tp" "$(d_pct "$flat_tp")" "$flat_err"
  printf '  %-10s %-20s %6s reqs (%3s%%)  %6s errors\n' gateway   "$GW_SVC"   "$gw_tp"   "$(d_pct "$gw_tp")"   "$gw_err"

  # Federation is the silent case: the pool is stale, so the client still
  # believes in backends that are gone, and the balancer routes around them
  # without anything being recorded as wrong.
  #
  # Bounded, not zero. The 2026-08-27 run asserted `== 0` and got 1: a single
  # in-flight request reached an east pod at the instant it was being scaled
  # away and took a 502. Relaxing a threshold to make a red check green is
  # usually the wrong move, so the reasoning is recorded rather than hidden --
  # "frozen discovery costs one request in 3251" is a SHARPER finding than
  # "zero errors", because it names the mechanism and bounds the cost. After
  # that one request the balancer's failure accrual routed around the dead
  # endpoints without discovery's help.
  fed_err_pm=$(( fed_tp > 0 ? fed_err * 1000 / fed_tp : 0 ))
  if [ "$fed_err_pm" -lt 1 ]; then
    check "federated failure is SILENT (errors < 0.1%)" pass \
      "${fed_err} of ${fed_tp} -- stale pool of 9, nothing surfaced it"
  else
    check "federated failure is SILENT (errors < 0.1%)" fail \
      "${fed_err} of ${fed_tp} -- something did surface it"
  fi

  # The flat mirror is the OTHER silent case, and the one that went unasserted
  # until now. On 2026-08-27 it served 567 requests against the federated
  # service's 3251 -- 17% -- while logging exactly ONE error, and the runner
  # printed that and passed. Its backends were gone and it had nowhere to fail
  # over to, so requests sat in the balancer queue until the client gave up,
  # and a request that never completes never increments response_total.
  #
  # This is the repo's own headline mechanism -- "error rate lies, throughput
  # does not" -- appearing in FM1 and going unchecked in the very experiment
  # that produced it. Assert on throughput.
  flat_pct="$(d_pct "$flat_tp")"
  if [ "$flat_pct" -lt 50 ]; then
    check "flat mirror collapses SILENTLY (control)" pass \
      "${flat_pct}% of expected on ${flat_err} errors"
  else
    check "flat mirror collapses SILENTLY (control)" fail \
      "${flat_pct}% of expected -- it did not collapse; check the backends really went away"
  fi

  # The gateway mirror is the loud case, and this is the claim under test.
  # Its endpoint -- east's gateway address -- is still perfectly valid; what
  # changed is behind it, inside a cluster whose control plane is healthy. So
  # the gateway answers, and it answers 5xx.
  #
  # If this FAILS, the interesting possibilities are: the gateway kept serving
  # (app-gateway did not actually scale down), or gateway requests hung the way
  # flat ones do (in which case the loud/silent distinction is not about the
  # mode but about who answers). Both are worth knowing; neither is a bug in
  # the harness.
  if [ "$gw_err" -gt 0 ]; then
    check "gateway mode SURFACES what discovery hid" pass "${gw_err} errors from a gateway whose backends are gone"
    printf '\n  Discovery is frozen in %s, yet the gateway mirror still reported the\n' "$TARGET"
    printf '  failure -- because a gateway mirror resolves its backends in the TARGET\n'
    printf '  cluster, whose control plane is fine. Pushing discovery across the\n'
    printf '  boundary trades silent staleness for a loud failure.\n'
    printf '\n  Note this inverts FM2 and FM4, where the gateway mirror is the worst\n'
    printf '  performer. Same property, opposite sign, depending on the fault.\n'
  else
    check "gateway mode SURFACES what discovery hid" fail "0 errors -- gateway mode was blinded too"
  fi

else
  # ------------------------------------------------------------------- identity
  banner "certificate headroom BEFORE breaking identity"
  bash "${REPO_ROOT}/verify/cert-headroom.sh" "$TARGET" 2>&1 | tail -12

  bash "${REPO_ROOT}/chaos/fm1-control-plane.sh" identity-down "$TARGET" 2>&1 | grep -E '  ok' || true
  sleep 10

  banner "does existing traffic keep working?"
  sleep "$SETTLE"
  snapshot during

  # All three modes are measured here, and the expectation is that they do NOT
  # differ. Identity loss is a property of this cluster's ability to issue
  # certificates to NEW pods; it says nothing about how a request is routed once
  # a proxy already holds one. Measuring it anyway is the point: leaving a mode
  # unmeasured is exactly what lets a reader assume it behaved differently.
  #
  # A mode that DOES fall away here would be the real finding, and it would mean
  # the identity outage reached something other than issuance.
  # Elapsed time between the two snapshots, NOT `RPS * SETTLE`.
  #
  # The nominal window undercounts: the real gap also contains the injection,
  # the settle, and the snapshot overhead. On 2026-08-27 this reported 113% of
  # expected for all three modes -- impossible for a healthy service at a fixed
  # rate, and the arithmetic backs that out exactly (3058 reqs / 30 rps = 101.9s
  # against an assumed 90s). FM2 fixed this after it reported 190% for a service
  # that was merely healthy; FM1 never inherited the fix.
  #
  # It biases UPWARD, which is the dangerous direction: a mode that had really
  # dropped to 88% would still have printed 100% and passed.
  elapsed=$(( t_during - t_baseline ))
  expected=$(( RPS * elapsed ))
  pct_of() { echo $(( $1 * 100 / (expected > 0 ? expected : 1) )); }

  fed_tp="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC" 1)"
  flat_tp="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FLAT_SVC" 1)"
  gw_tp="$(mode_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$GW_SVC" 1)"

  printf '\n  throughput over %ss (%s expected per mode):\n' "$elapsed" "$expected"
  printf '    %-10s %-20s %6s reqs  (%s%%)\n' federated "$FED_SVC"  "$fed_tp"  "$(pct_of "$fed_tp")"
  printf '    %-10s %-20s %6s reqs  (%s%%)\n' flat      "$FLAT_SVC" "$flat_tp" "$(pct_of "$flat_tp")"
  printf '    %-10s %-20s %6s reqs  (%s%%)\n' gateway   "$GW_SVC"   "$gw_tp"   "$(pct_of "$gw_tp")"

  tp="$fed_tp"
  pct="$(pct_of "$fed_tp")"

  banner "can we scale up? (every failover plan assumes yes)"
  log "scaling ${TARGET}/app 3 -> 6 with identity unavailable"
  kubectl --context="$CTX" -n "$APP_NS" scale deploy app --replicas=6 >/dev/null

  t0="$(now)"; ready=""
  deadline=$(( t0 + 120 ))
  while [ "$(now)" -lt "$deadline" ]; do
    r="$(kubectl --context="$CTX" -n "$APP_NS" get deploy app -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    printf '\r  t+%-3ss  readyReplicas = %-4s (want 6)' "$(( $(now) - t0 ))" "${r:-0}"
    if [ "${r:-0}" = "6" ]; then ready="$(( $(now) - t0 ))"; break; fi
    sleep 5
  done
  echo

  printf '\nnew pods and their container counts:\n'
  kubectl --context="$CTX" -n "$APP_NS" get pods -l app=app --no-headers 2>/dev/null \
    | awk '{printf "  %-40s %-6s %s\n", $1, $2, $3}'

  banner "results"
  if [ "$pct" -ge 80 ]; then
    check "existing traffic survives identity loss" pass "${pct}% of expected throughput"
  else
    check "existing traffic survives identity loss" fail "only ${pct}%"
  fi

  # Assert the non-difference rather than just printing it. All three modes are
  # driven at the same rate, so if identity loss were selective one of them
  # would fall away and this would catch it.
  # `if`, not `&&`: a false test as the loop's last command makes the loop
  # itself return non-zero, which `set -e` treats as fatal.
  low="$fed_tp"
  for v in "$flat_tp" "$gw_tp"; do
    if [ "$v" -lt "$low" ]; then low="$v"; fi
  done
  if [ "$(pct_of "$low")" -ge 80 ]; then
    check "identity loss does not discriminate between modes" pass \
      "worst mode still at $(pct_of "$low")%"
  else
    check "identity loss does not discriminate between modes" fail \
      "worst mode at $(pct_of "$low")% -- one mode was hit and the others were not"
  fi

  if [ -z "$ready" ]; then
    check "scale-up BLOCKED without identity" pass "never reached 6 replicas in 120s"
    printf '\n  Existing pods are fine. New ones cannot join the mesh, so the\n'
    printf '  capacity you were counting on for failover does not arrive.\n'
  else
    check "scale-up BLOCKED without identity" fail "reached 6 replicas in ${ready}s"
  fi
fi

bash "${REPO_ROOT}/verify/annotate.sh" end "$annot_start" \
  "FM1 ${MODE}: control plane down in ${TARGET}" "fm1" >/dev/null 2>&1 || true

echo
printf 'raw metric snapshots written to %s\n' "$RESULTS"
[ "$fails" -eq 0 ] || die "${fails} check(s) failed"
ok "FM1 (${MODE}) complete"
