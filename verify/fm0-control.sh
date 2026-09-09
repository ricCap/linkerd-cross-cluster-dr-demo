#!/usr/bin/env bash
# FM0: the null experiment. Inject nothing, measure everything.
#
#   verify/fm0-control.sh
#   SETTLE=90 verify/fm0-control.sh
#
# WHY THIS EXISTS
#
# Every other runner compares a fault window against a baseline and reports the
# difference as a result. None of them establishes what that comparison reads
# when NOTHING is wrong -- so there is no measurement of the noise floor, and no
# way to tell a small real effect from instrument error.
#
# That is not hypothetical here. An earlier version of the throughput
# calculation "reported 190% of expected for a service that was merely healthy"
# (see the comment in fm2-verify.sh). A 90% error in the measurement was found
# by chance, in a fault run, because the number looked odd. This run would have
# caught it immediately and for free.
#
# It runs the same code path as fm2-verify.sh -- same snapshots, same deltas,
# same denominators -- with the injection step removed. Anything that is not
# ~100% of expected, ~0 errors, and a stable endpoint pool is measurement error,
# and every fault result inherits it.
#
# Run it before a measurement sweep, and after any change to lib.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need linkerd kubectl

OBSERVER="${OBSERVER:-west}"
SETTLE="${SETTLE:-90}"

FED_SVC="$(modes_for "$OBSERVER" | awk '$1 == "federated" { print $2 }')"
FLAT_SVC="$(modes_for "$OBSERVER" | awk '$1 == "flat"      { print $2 }')"
GW_SVC="$(modes_for "$OBSERVER"  | awk '$1 == "gateway"   { print $2 }')"

# Namespaced by PROFILE. Both arms used to write here, so running the second
# sweep destroyed the first one's raw snapshots -- Arm B overwrote Arm A on
# 2026-09-08 and only the SUMMARY files and TSDB archives survived.
RESULTS="${REPO_ROOT}/results/${PROFILE:-default}/fm0-control"
mkdir -p "$RESULTS"
echo "$OBSERVER" > "${RESULTS}/observer"

# The node address table, for the same reason every other runner copies it:
# gateway mirrors resolve to a NODE address rather than a pod IP, so attributing
# them to a cluster needs this file. Without it the gateway lane reports
# "other 100%" on the published replay -- unknown attribution, not unknown
# destination, but it reads like a hole in the data. fm0 is the run people look
# at first, so it is the worst one to leave looking broken.
[ -f "$(ip_state_file)" ] || save_node_ips $(clusters)
cp -f "$(ip_state_file)" "${RESULTS}/node-ips.txt" 2>/dev/null || true
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

# fm0 samples too: it is the run that establishes the noise floor, so the live
# feed should show what "nothing wrong" looks like next to the fault runs.
# Label BEFORE sampling starts. The phase file persists between runs, so a
# sampler started first records its opening samples under the PREVIOUS run's
# phase -- observed as a stray "restored" at the head of a baseline window.
mark_phase baseline
sampler_start
trap sampler_stop EXIT

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

snapshot() {
  local label="$1"
  proxy_responses "$OBSERVER" > "${RESULTS}/${label}.metrics"
  record_node_state "${RESULTS}/${label}.nodes"
  k6_client_view "$OBSERVER"  > "${RESULTS}/${label}.client"
}

throughput_delta() {
  local before after
  before="$(mode_totals "$(cat "$1")" "$3" | awk '{print $1}')"
  after="$(mode_totals "$(cat "$2")" "$3" | awk '{print $1}')"
  counter_delta "$before" "$after" "request count for $3"
}
error_delta() {
  local before after
  before="$(mode_totals "$(cat "$1")" "$3" | awk '{print $2}')"
  after="$(mode_totals "$(cat "$2")" "$3" | awk '{print $2}')"
  counter_delta "$before" "$after" "error count for $3"
}

banner "FM0 control -- no fault injected, observed from '${OBSERVER}'"

expected_pool="$(federated_pool_size)"
# The destination view, like every other membership check in this repo. At rest
# adaptive_endpoints does read correctly -- but this is the run that certifies
# the instrument for every other run, so it should not be the one place still
# asking a metric the rest of the suite has stopped trusting.
pool_before="$(destination_endpoints "$OBSERVER" "$FED_SVC")"
t0="$(now)"
snapshot baseline

log "holding ${SETTLE}s with nothing wrong"
sleep "$SETTLE"

t1="$(now)"
snapshot during
pool_after="$(destination_endpoints "$OBSERVER" "$FED_SVC")"

elapsed=$(( t1 - t0 ))
nominal=$(( ${RPS:-30} * elapsed ))

c_before="$(awk '{print $1}' "${RESULTS}/baseline.client" 2>/dev/null)"
c_after="$(awk '{print $1}' "${RESULTS}/during.client" 2>/dev/null)"
# Field 3 is dropped_iterations. Defaulted, because the whole line reads "- - - -"
# when the k6 API is unreachable and bare arithmetic on that is a syntax error.
d_now="$(awk '{print $3}'  "${RESULTS}/during.client"   2>/dev/null | cut -d. -f1)"
d_pre="$(awk '{print $3}'  "${RESULTS}/baseline.client" 2>/dev/null | cut -d. -f1)"
case "${d_now:-}" in ''|*[!0-9]*) d_now=0 ;; esac
case "${d_pre:-}" in ''|*[!0-9]*) d_pre=0 ;; esac
dropped=$(( d_now - d_pre ))

if [ -n "${c_before:-}" ] && [ "$c_before" != "-" ] && [ -n "${c_after:-}" ] && [ "$c_after" != "-" ]; then
  # Derived: this observer may source two modes or three. See fm2-verify.sh.
  n_modes="$(modes_for "$OBSERVER" | wc -l | tr -d ' ')"
  attempted=$(( ( ${c_after%%.*} - ${c_before%%.*} ) / n_modes ))
else
  attempted=""
fi

pct() { [ "${2:-0}" -eq 0 ] && echo 0 || echo $(( $1 * 100 / $2 )); }

printf '\nover %ss with no fault (nominal ~%s per mode):\n' "$elapsed" "$nominal"
for mode in $(modes_for "$OBSERVER" | awk '{print $2}'); do
  tp="$(throughput_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$mode")"
  er="$(error_delta      "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$mode")"
  printf '  %-20s %6s reqs  %3s%% of nominal  %s errors\n' \
    "$mode" "$tp" "$(pct "$tp" "$nominal")" "$er"
done

if [ -n "$attempted" ]; then
  printf '\nclient issued ~%s per mode (%s%% of nominal), dropped %s iterations\n' \
    "$attempted" "$(pct "$attempted" "$nominal")" "$dropped"
else
  warn "k6 API unreachable -- cannot report what the client actually offered"
fi

printf '\n%-42s %s\n' CHECK RESULT
printf -- '-------------------------------------------------------------\n'
fails=0
notes=""
check() {
  if [ "$2" = "pass" ]; then printf '%-42s \033[1;32mPASS\033[0m  %s\n' "$1" "$3"
  else printf '%-42s \033[1;31mFAIL\033[0m  %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

# A healthy run must land close to nominal on every mode. Wide band (80-120%)
# because this is a noise floor, not a performance test -- but 190% must fail.
for mode in $(modes_for "$OBSERVER" | awk '{print $2}'); do
  tp="$(throughput_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$mode")"
  p="$(pct "$tp" "$nominal")"
  if [ "$p" -ge 80 ] && [ "$p" -le 120 ]; then
    check "throughput sane: ${mode}" pass "${p}% of nominal"
  else
    check "throughput sane: ${mode}" fail "${p}% of nominal"
    notes="${notes}
  ${mode} read ${p}% with nothing wrong. The measurement is wrong, not the mesh,
  and every fault result inherits it."
  fi
done

fed_err="$(error_delta "${RESULTS}/baseline.metrics" "${RESULTS}/during.metrics" "$FED_SVC")"
if [ "$fed_err" -eq 0 ]; then
  check "no errors with no fault" pass "0"
else
  check "no errors with no fault" fail "${fed_err} errors on a healthy mesh"
fi

if [ "${pool_before:-0}" = "$expected_pool" ] && [ "${pool_after:-0}" = "$expected_pool" ]; then
  check "endpoint pool stable at ${expected_pool}" pass "${pool_before} -> ${pool_after}"
else
  check "endpoint pool stable at ${expected_pool}" fail "${pool_before} -> ${pool_after}"
fi

if [ "${dropped:-0}" -le 0 ]; then
  check "client offered the full configured rate" pass "0 dropped iterations"
else
  check "client offered the full configured rate" fail "${dropped} dropped"
  notes="${notes}
  k6 dropped ${dropped} iterations with nothing wrong, so it cannot sustain the
  configured rate at rest. Every '% of expected' is then measured against a rate
  that was never offered. Raise maxVUs in load/steady.js."
fi

# A restart is the likeliest innocent explanation, so rule it in before blaming
# the instrument. Observed: a control run started ~90s after `enforce on`
# restarted every workload read 32% / 52% / 100% across the three modes -- the
# federated service worst, because it has the most endpoints to re-establish and
# the gateway mirror least, since it resolves to a stable node address rather
# than pod IPs. Nothing was wrong; the rig had not settled.
if [ -n "$notes" ]; then
  youngest=$(kubectl --context="$(ctx "$OBSERVER")" -n "$APP_NS" get pods \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null \
    | sort | tail -1)
  if [ -n "$youngest" ]; then
    age=$(( $(now) - $(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$youngest" +%s 2>/dev/null \
            || date -d "$youngest" +%s 2>/dev/null || echo 0) ))
    if [ "$age" -gt 0 ] && [ "$age" -lt 180 ]; then
      notes="${notes}
  A pod in ${APP_NS} is only ${age}s old, so the rig is still settling after a
  restart. That alone explains a low reading -- wait ~3 minutes and re-run
  before concluding the measurement is broken."
    fi
  fi
fi

[ -z "$notes" ] || printf '\n\033[1;33mwhy this matters\033[0m%s\n' "$notes"
echo
[ "$fails" -eq 0 ] || die "${fails} control check(s) failed. Fix the measurement before
     trusting any fault result -- a broken instrument reports confident numbers."
ok "measurement is sound: the instrument reads clean when nothing is wrong"
