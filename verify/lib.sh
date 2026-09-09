#!/usr/bin/env bash
# Measurement helpers shared by the experiment runners.
#
# Everything here reads the load generators' own linkerd-proxy metrics. Those
# counters are cumulative, so experiments work by taking deltas between marks
# rather than by reading instantaneous values.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

# Raw response_total lines from a cluster's load generator.
proxy_responses() {
  linkerd --context="$(ctx "$1")" diagnostics proxy-metrics \
    -n "$APP_NS" deploy/loadgen 2>/dev/null | grep '^response_total{' || true
}

# cluster_of_ip lives in clusters/lib.sh, sourced above. Linkerd puts no cluster
# label on remote-discovery endpoints, so the address is the only identifier --
# and gateway mirrors resolve to a node address rather than a pod IP, which is
# why that function needs more than the CIDR table.

# Totals for one exposure mode, as: <total> <errors> <non_tls>
# Usage: mode_totals "<metrics>" <authority-prefix>
mode_totals() {
  echo "$1" | grep "authority=\"${2}\." | awk '
    {
      n = $NF + 0
      match($0, /status_code="[^"]*"/); code = substr($0, RSTART+13, RLENGTH-14)
      match($0, /tls="[^"]*"/);         tls  = substr($0, RSTART+5,  RLENGTH-6)
      total += n
      if (code !~ /^2/) errors += n
      if (tls != "true") nontls += n
    }
    END { printf "%d %d %d\n", total+0, errors+0, nontls+0 }'
}

# Deltas for one mode between two snapshots, over series present in BOTH.
#
#   mode_totals_delta <before-file> <after-file> <mode>
# Prints "<total> <errors> <nontls>".
#
# WHY THIS EXISTS
#
# mode_totals sums whatever series a snapshot happens to contain, and the proxy
# EVICTS series for endpoints that no longer exist. So when a fault removes a
# cluster, its series are in the baseline and gone from the `during` snapshot,
# and subtracting one sum from the other silently discards traffic that was
# genuinely served before the fault.
#
# Measured on FM2a, 2026-09-08: baseline held 4 app-federated series (2 in
# east), `during` held 3 (1 in east). Federated throughput was reported as
# **2275, 76% of expected, FAIL** -- while distribution_delta, which is keyed
# per series and drops negatives, reported **2952 against 2955 expected**, which
# is 100%. The mesh held throughput perfectly; the arithmetic did not.
#
# results/FINDINGS.md has prescribed the fix since the 2026-08-17 run -- "delta
# only over series present in both snapshots, keyed on the full label set" --
# and it was never applied to the throughput path. It is applied here.
#
# The label set minus the trailing value is the key. Series only in `before`
# (evicted) and series only in `after` (new pods) are both skipped: neither can
# yield a meaningful delta, and including either invents traffic.
mode_totals_delta() {
  local before="$1" after="$2" mode="$3"
  awk -v mode="$mode" '
    function key(line,   k) { k = line; sub(/ [^ ]*$/, "", k); return k }
    function val(line,   v) { v = line; sub(/^.* /, "", v); return v + 0 }
    FNR == NR {
      if (index($0, "authority=\"" mode ".")) b[key($0)] = val($0)
      next
    }
    {
      if (!index($0, "authority=\"" mode ".")) next
      k = key($0)
      if (!(k in b)) next          # new series: no baseline to subtract
      d = val($0) - b[k]
      if (d < 0) next              # counter reset for this series
      match($0, /status_code="[^"]*"/); code = substr($0, RSTART+13, RLENGTH-14)
      match($0, /tls="[^"]*"/);         tls  = substr($0, RSTART+5,  RLENGTH-6)
      total += d
      if (code !~ /^2/) errors += d
      if (tls != "true") nontls += d
    }
    END { printf "%d %d %d\n", total+0, errors+0, nontls+0 }
  ' "$before" "$after"
}

# Per-destination-cluster request counts for one exposure mode.
# Emits "<cluster> <count>" lines.
mode_distribution() {
  local metrics="$1" mode="$2" line n ip
  echo "$metrics" | grep "authority=\"${mode}\." | while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line##* }"; n="${n%%.*}"
    ip="$(echo "$line" | sed -n 's/.*target_ip="\([^"]*\)".*/\1/p')"
    echo "$(cluster_of_ip "$ip") $n"
  done | awk 'NF {a[$1]+=$2} END {for (k in a) print k, a[k]}' | sort
}

# Per-destination-cluster counts BETWEEN two snapshots.
#
# Use this, not mode_distribution, whenever you are reporting "where did traffic
# go during the failure". The proxy counters are cumulative, so the raw
# distribution during an outage still shows a large count for the dead cluster
# -- all of it accumulated before the fault. That reads as "the dead cluster is
# still serving traffic", which is exactly backwards.
#
#   distribution_delta <before.metrics> <after.metrics> <mode>
distribution_delta() {
  local mode="$3"
  {
    mode_distribution "$(cat "$1")" "$mode" | sed 's/^/before /'
    mode_distribution "$(cat "$2")" "$mode" | sed 's/^/after /'
  } | awk '
      $1 == "before" { b[$2] = $3 }
      $1 == "after"  { a[$2] = $3 }
      END {
        for (k in a) { d = a[k] - (k in b ? b[k] : 0); if (d > 0) { print k, d; total += d } }
        if (total > 0) printf "TOTAL %d\n", total
      }' | sort
}

# Federation membership: how many endpoints does this service have AVAILABLE?
#
# The naive metric is wrong under BEL. HAZL splits the two concepts:
#
#   outbound_http_balancer_adaptive_endpoints   all endpoints available (9)
#   outbound_http_balancer_endpoints{ready}     the subset HAZL is USING (3)
#
# On OSS there is no adaptive metric and endpoints{ready} is the whole pool, so
# it means "available". On BEL, endpoints{ready} means "currently in the active
# zone-local subset" -- with 9 federated endpoints and traffic staying in-zone
# it reads 3. Asserting a baseline of 9 against it fails on BEL for a reason
# that has nothing to do with federation.
#
# Prefer the adaptive metric when present; fall back to the OSS one.
endpoint_pool() {
  local metrics
  metrics="$(linkerd --context="$(ctx "$1")" diagnostics proxy-metrics \
    -n "$APP_NS" deploy/loadgen 2>/dev/null)"

  local n
  n="$(echo "$metrics" | awk -v svc="$2" '
        $0 ~ /^outbound_http_balancer_adaptive_endpoints\{/ && $0 ~ ("parent_name=\"" svc "\"") && !seen {
          v = $NF; seen = 1 }
        END { if (seen) print v }' | sed 's/\..*//')"
  if [ -n "$n" ]; then echo "$n"; return; fi

  echo "$metrics" | awk -v svc="$2" '
      $0 ~ /^outbound_http_balancer_endpoints\{endpoint_state="ready"/ && $0 ~ ("parent_name=\"" svc "\"") && !seen {
        v = $NF; seen = 1 }
      END { if (seen) print v }' | sed 's/\..*//'
}

# How many endpoints is HAZL actively sending to right now (BEL only).
# Empty on OSS. This is the number that STEPS UP when the load band is crossed.
active_endpoints() {
  # No early `exit` in awk: it closes the pipe while the linkerd CLI is still
  # writing, the CLI dies with SIGPIPE, and `pipefail` turns that into a 141
  # that `set -e` treats as fatal. It is a race against the pipe buffer, so it
  # fails intermittently -- the worst kind. Read the whole stream.
  linkerd --context="$(ctx "$1")" diagnostics proxy-metrics \
    -n "$APP_NS" deploy/loadgen 2>/dev/null \
    | awk -v svc="$2" '
        $0 ~ /^outbound_http_balancer_endpoints\{endpoint_state="ready"/ && $0 ~ ("parent_name=\"" svc "\"") && !seen {
          v = $NF; seen = 1 }
        END { if (seen) print v }' | sed 's/\..*//'
}

# HAZL load average and its band, as "<load> <low> <high>". Empty on OSS.
#
# The band is NOT the documented 0.8 / 2.0. Those are PER-ENDPOINT values; the
# exposed band is the aggregate for the active pool, so with 3 active endpoints
# it reads 2.4 / 6.0. Measured ratios were exactly 0.80 and 2.00 per endpoint
# across every service. Use these metrics rather than assuming the defaults.
hazl_load() {
  linkerd --context="$(ctx "$1")" diagnostics proxy-metrics \
    -n "$APP_NS" deploy/loadgen 2>/dev/null \
    | awk -v svc="$2" '
        $0 ~ ("parent_name=\"" svc "\"") {
          if ($0 ~ /^outbound_http_balancer_adaptive_load_average\{/)   l=$NF
          if ($0 ~ /^outbound_http_balancer_adaptive_load_band_low\{/)  lo=$NF
          if ($0 ~ /^outbound_http_balancer_adaptive_load_band_high\{/) hi=$NF
        }
        END { if (l != "") printf "%.3f %.2f %.2f\n", l, lo, hi }'
}

# Wait until traffic to <cluster> stops, and report how long it took.
#
# WHY NOT ENDPOINT COUNTS
#
# Counting endpoints is the obvious convergence signal and it is unreliable:
#
#   - On OSS, endpoints{ready} is the whole pool and drops cleanly 9 -> 6.
#   - Under HAZL the same metric is the zone-local ACTIVE subset (3), and
#     adaptive_endpoints -- the discovery-level total -- lags. Measured during a
#     graceful cluster stop it sat at 8 rather than 6 for the whole 90s window,
#     while actual traffic to the dead cluster had already fallen to 12 requests
#     out of 5487. The balancer had stopped using it; the count had not caught up.
#   - The 2026-08-27 run settled it with three independent demonstrations in one
#     day: adaptive_endpoints dipped 9 -> 5 during FM3, a purely latency-shaped
#     fault where membership CANNOT change; it never reached 3 in FM4 while
#     100% throughput, zero errors and zero requests to the dead region all said
#     failover was complete; and an interrupted run left west reporting 13
#     against 9 real pods. It is not a membership signal. Do not check on it.
#
# Traffic is what the user experiences and what the SLO is written against, and
# it means the same thing on both flavors. Time-to-zero-traffic is the metric.
#
# RESOLUTION, AND WHY IT WAS WORTH FIXING
#
# This polled every 5s and subtracted 10, so results were quantised in ~5s steps
# plus the cost of the CLI calls inside the loop. That is fine for the 82s hard
# partition and useless for the 6s graceful stop, which is one or two poll
# cycles -- the instrument could not tell 1s from 8s. Quoting "13x" off a pair
# where one end sits on the noise floor is not defensible, so: poll every 1s,
# take ONE metrics snapshot per poll and derive everything from it (which also
# halves the CLI calls the old version made), and report the resolution
# alongside the number so a caller cannot quote it as if it were exact.
#
# STALL AMBIGUITY
#
# "The counter for the dead cluster stopped advancing" and "the load generator
# stopped generating" are the same observation. That is not hypothetical: k6
# starves for VUs precisely when requests hang, which is exactly what these
# faults cause. So sample total traffic for the mode in the same snapshot -- if
# THAT flatlines too, the generator died and there is no convergence to report.
# Returning a convergence time there would be inventing a result.
#
#   converge_by_traffic <source> <mode> "<dead-cluster...>" <timeout-s>
# Prints "<elapsed> <resolution>" on convergence, nothing otherwise.
#
# <dead-cluster...> may be several names in one quoted argument, for a fault
# that removes more than one cluster at a time (FM4). Convergence is then the
# moment traffic to the whole set stops.
converge_by_traffic() {
  local src="$1" mode="$2" dead="$3" timeout="${4:-120}"
  local interval=1 need_stable=3
  local t0 metrics dead_now total_now dead_last total_last stable=0 total_stalled=0
  local t_sample t_prev gap max_gap=0

  t0="$(now)"
  metrics="$(proxy_responses "$src")"
  t_prev="$(now)"
  dead_last="$(_requests_to_cluster_from "$metrics" "$mode" "$dead")"
  total_last="$(mode_totals "$metrics" "$mode" | awk '{print $1}')"

  while [ "$(( $(now) - t0 ))" -lt "$timeout" ]; do
    sleep "$interval"
    metrics="$(proxy_responses "$src")"
    # Report the spacing actually achieved, not the nominal sleep. Each poll
    # also costs a CLI round trip, so claiming the sleep as the tolerance would
    # understate it -- the same overclaiming this rewrite exists to stop.
    t_sample="$(now)"; gap=$(( t_sample - t_prev )); t_prev="$t_sample"
    [ "$gap" -gt "$max_gap" ] && max_gap="$gap"
    dead_now="$(_requests_to_cluster_from "$metrics" "$mode" "$dead")"
    total_now="$(mode_totals "$metrics" "$mode" | awk '{print $1}')"

    # Is the generator still producing anything at all for this mode?
    if [ "${total_now:-0}" -eq "${total_last:-0}" ]; then
      total_stalled=$(( total_stalled + 1 ))
    else
      total_stalled=0
    fi

    if [ "${dead_now:-0}" -eq "${dead_last:-0}" ]; then
      stable=$(( stable + 1 ))
      if [ "$stable" -ge "$need_stable" ]; then
        # Traffic to the dead cluster stopped -- but if ALL traffic stopped at
        # the same time, this is a dead generator, not a converged mesh.
        if [ "$total_stalled" -ge "$need_stable" ]; then
          warn "convergence is ambiguous: traffic to '${dead}' stopped, but so did
     ALL traffic for '${mode}'. The load generator is not producing requests --
     check 'kubectl -n ${APP_NS} logs deploy/loadgen -c k6' for dropped
     iterations. Refusing to report a convergence time."
          return 1
        fi
        echo "$(( $(now) - t0 - need_stable * interval )) ${max_gap}"
        return 0
      fi
    else
      stable=0
    fi
    dead_last="$dead_now"
    total_last="$total_now"
  done
  return 1
}

# Cumulative requests to endpoints in <cluster...> for <mode>, from an ALREADY
# CAPTURED metrics blob. Split out so the convergence loop can take one snapshot
# per poll and answer several questions from it.
#
# <cluster...> is a space-separated SET, not a single name, because FM4 loses a
# whole region: two clusters stop answering at the same instant and convergence
# is the moment traffic to EITHER of them stops. Timing them one at a time would
# start the second clock after the first had already converged.
_requests_to_cluster_from() {
  local metrics="$1" mode="$2" want="$3"
  # `if`, not `[ cond ] && assign`: under `set -e` a false compound is fatal and
  # aborts the pipeline with no message. See "Two shell bugs that produced
  # silent, wrong results" in results/FINDINGS.md -- this is that bug's shape.
  echo "$metrics" | grep "authority=\"${mode}\." \
    | sed -n 's/.*target_ip="\([^"]*\)".*} \([0-9][0-9]*\)$/\1 \2/p' \
    | while read -r ip n; do
        owner="$(cluster_of_ip "$ip")"
        for c in $want; do
          if [ "$owner" = "$c" ]; then echo "$n"; break; fi
        done
      done | awk '{s+=$1} END {print s+0}'
}

# Counter deltas that refuse to invent results.
#
# distribution_delta already dropped negatives with a comment explaining why;
# throughput and error deltas did not, so a load generator pod that restarted
# mid-run -- counters back to zero, and the generator IS the instrument here --
# produced a negative delta that flowed straight into a percentage and a
# PASS/FAIL. Silent and plausible, the worst combination.
#
#   counter_delta <before> <after> <what>
# Prints the delta, or dies if the counter went backwards.
counter_delta() {
  local before="${1:-0}" after="${2:-0}" what="${3:-counter}"
  if [ "$after" -lt "$before" ]; then
    die "${what} went backwards (${before} -> ${after}).

     A single cumulative counter cannot decrease, so one of two things happened,
     and they need different responses. Check which before doing anything:

       1. The load generator pod restarted and its metrics reset.
          Confirm:  kubectl -n ${APP_NS} get pods -l app=loadgen
          A non-zero restartCount, or an age younger than this run.

       2. The SUM went down because the population of series changed under it.
          mode_totals adds up whatever response_total series a snapshot holds,
          and the proxy evicts series for pods that no longer exist. So a
          baseline taken while old pods' series were still present, compared
          against a snapshot taken after they were evicted, subtracts series
          that were never replaced. No counter moved backwards; the set did.
          Confirm:  the pod has restartCount=0 and predates the run, and a
          recent experiment restarted or rescaled workloads.

     Cause 2 is the common one straight after a fault run, and the fix is to
     wait for the series to settle before baselining rather than to rerun
     immediately. results/FINDINGS.md records the durable fix -- delta only over
     series present in BOTH snapshots, keyed on the full label set -- which
     distribution_delta does and this does not."
  fi
  echo $(( after - before ))
}

# Age of the youngest pod in the app namespace, in seconds. 0 if unknown.
pod_settle_age() {
  local c youngest
  c="$(ctx "$1")"
  youngest="$(kubectl --context="$c" -n "$APP_NS" get pods \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null \
    | sort | tail -1)"
  [ -n "$youngest" ] || { echo 0; return; }
  echo $(( $(now) - $(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$youngest" +%s 2>/dev/null \
          || date -d "$youngest" +%s 2>/dev/null || echo 0) ))
}

# Refuse to baseline a rig that is still coming up.
#
# A baseline taken during the re-establishment window poisons every delta in the
# run, and it does it QUIETLY -- the numbers look like a real effect. Measured:
# a control run started ~90s after a workload restart read 32% / 52% / 100%
# across the three exposure modes with nothing wrong. The federated service was
# worst because it has the most endpoints to re-establish; the gateway mirror
# was unaffected because it resolves to a stable node address rather than pod
# IPs. That is a plausible-looking three-mode result, and it is pure artifact.
#
# verify/fm0-control.sh already knew this and used it to EXPLAIN a bad reading
# after the fact. A fault runner cannot afford that: by the time the number is
# odd, the fault has been injected and the window is gone. Check it first.
#   require_settled <cluster> [cluster...]
#
# Takes EVERY cluster the experiment touches, not just the one it breaks.
#
# It used to take one. FM1 breaks the control plane in `central` and scales the
# backends away in `east`, so guarding only `central` watched the cluster where
# nothing had moved. A back-to-back run then baselined with the destination view
# already at 6 of 9, because east's pods had not finished coming back from the
# previous run -- and the guard could not see the cluster that was unsettled.
require_settled() {
  local src age worst=0 worst_c=""
  # `if`, not `[ ] && { }`: a false compound mid-function is fatal under set -e.
  if [ "${SETTLE_GUARD:-1}" = "0" ]; then
    warn "settle guard disabled (SETTLE_GUARD=0) -- do not publish from this run"
    return 0
  fi
  for src in "$@"; do
    [ -n "$src" ] || continue
    age="$(pod_settle_age "$src")"
    if [ "${age:-0}" -gt 0 ] && [ "${age:-0}" -lt 180 ]; then
      die "a pod in ${APP_NS} is only ${age}s old, so '${src}' is still settling.
     Endpoints are still being re-established, and a baseline taken now makes
     every delta in this run meaningless -- while looking like a real result.
     Wait $(( 180 - age ))s and re-run. Set SETTLE_GUARD=0 to override, but a
     run that overrides it is not one to publish from."
    fi
    if [ "${age:-0}" -gt "$worst" ]; then worst="$age"; worst_c="$src"; fi
  done
  ok "rig is settled across [$*] (youngest pod ${worst}s old, in ${worst_c})"
}

# Refuse to start unless the mesh's own view of <mode> is the expected size.
#
#   require_baseline_view <cluster> <service> <expected>
#
# Distinct from require_settled, which only knows about pod AGE. A deployment
# scaled to zero by a previous run has no young pods at all, so age tells you
# nothing -- and that is exactly the state a back-to-back run inherits.
#
# Reads the destination controller rather than endpoint_pool. FM1 already
# asserted a baseline of 9 here and it passed while the real view was 6, because
# it asked adaptive_endpoints, which is a balancer signal and not a membership
# one. An entry guard that consults an unreliable instrument is worse than none:
# it certifies the thing it failed to check.
require_baseline_view() {
  local src="$1" svc="$2" want="$3" have
  have="$(destination_endpoints "$src" "$svc")"
  if [ "${have:-0}" != "$want" ]; then
    die "'${src}' sees ${have:-?} endpoints for ${svc}, expected ${want}.
     The mesh is not at its baseline, so every delta in this run would be
     measured from the wrong starting point. The usual cause is a previous
     experiment whose backends have not finished coming back -- check the peer
     clusters, not just this one, and re-run when it reads ${want}."
  fi
  ok "baseline view is ${have} for ${svc}, as seen by ${src}"
}

# What the DESTINATION CONTROLLER thinks the endpoints are, for <mode> as seen
# from <cluster>. Prints a count.
#
# WHY NOT endpoint_pool
#
# endpoint_pool resolves to adaptive_endpoints under BEL, which is a BALANCER
# signal and which this repo has established three separate times is not a
# membership signal at all. FM1 asks a question about the mesh's VIEW -- "did
# this cluster learn that endpoints went away?" -- and the balancer's opinion of
# how many endpoints it is currently willing to use is not that.
#
# WHY NOT TRAFFIC EITHER
#
# FM2 and FM4 time convergence from traffic, and that is right for them. It is
# wrong here. FM1a established that the proxy's failure accrual routes around
# dead endpoints WHETHER OR NOT discovery is frozen -- that was the whole
# finding. So traffic to the removed endpoints stops in both arms and cannot
# discriminate between them.
#
# `linkerd diagnostics endpoints` queries destination directly, which is exactly
# the view under test. It is also already on the runbook list for the post.
#
#   destination_endpoints <cluster> <service-name>
destination_endpoints() {
  local src="$1" svc="$2" c port
  c="$(ctx "$src")"
  port="$(kubectl --context="$c" -n "$APP_NS" get svc "$svc" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
  [ -n "$port" ] || { echo ""; return; }
  # `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so `... || echo 0`
  # emitted "0\n0" -- which then rendered as a two-line check message and would
  # have broken any arithmetic downstream. Count without the fallback.
  linkerd --context="$c" diagnostics endpoints \
    "${svc}.${APP_NS}.svc.cluster.local:${port}" 2>/dev/null \
    | tail -n +2 | grep -c . | head -1
}

# The PROXY's own view of total membership for <mode>, from <cluster>.
#
# Reads outbound_http_balancer_adaptive_endpoints, and the distinction from
# endpoint_pool's fallback matters. On BEL, measured on this rig:
#
#   outbound_http_balancer_endpoints{endpoint_state="ready"}  3   HAZL's ACTIVE subset
#   outbound_http_balancer_adaptive_endpoints                 9   the total it knows about
#
# So "how many endpoints does this proxy know about" is the adaptive series, and
# verify/metrics.md already said so.
#
# WHEN TO USE THIS RATHER THAN destination_endpoints
#
# When the destination controller is the thing that is broken. FM1a scales it to
# zero, so asking it anything returns nothing -- and a check that compares
# "nothing" to "nothing" passes vacuously, which is exactly what it did before
# this existed.
#
# Note the earlier blanket claim that adaptive_endpoints "is not a membership
# signal" was too broad. It IS this proxy's view of membership. What it does
# unreliably is track membership WHILE IT IS CHANGING -- it dipped 9 to 5 during
# a latency-only fault and never reached 3 during FM4's failover. FM1a is the
# opposite situation: nothing should change, and the finding is that nothing
# does. At rest it is the correct instrument.
proxy_endpoint_view() {
  linkerd --context="$(ctx "$1")" diagnostics proxy-metrics \
    -n "$APP_NS" deploy/loadgen 2>/dev/null \
    | awk -v svc="$2" '
        $0 ~ /^outbound_http_balancer_adaptive_endpoints\{/ && $0 ~ ("parent_name=\"" svc "\"") && !seen {
          v = $NF; seen = 1 }
        END { if (seen) print v }' | sed 's/\..*//'
}

# Refuse to start if any workload is outside the mesh.
#
#   require_meshed <cluster> [cluster...]
#
# require_baseline_view counts endpoints. It cannot see that one of them has no
# proxy, and this exercise's own headline finding is that a recovered cluster
# brings workloads back unmeshed -- so the state this guard exists to catch is
# the EXPECTED outcome of the experiment that ran before.
#
# Measured on 2026-09-08: FM4 baselined with 469 plaintext requests already
# recorded against an east pod (tls=no_identity,
# no_tls_reason=not_provided_by_service_discovery), left behind by FM2b's
# recovery. FM4's mTLS check then reported "2 non-mTLS" -- a correct delta on
# top of contamination, and a red check whose real cause was in the previous
# experiment. Every mTLS number in a run that starts like this describes the
# rig's history rather than the fault.
require_meshed() {
  local src c bad total
  for src in "$@"; do
    [ -n "$src" ] || continue
    c="$(ctx "$src")"
    # A meshed pod runs the proxy as a native sidecar INIT container from
    # Kubernetes 1.29, so checking .spec.containers alone reports every healthy
    # pod as broken -- that mistake produced 52 false positives once already.
    bad="$(kubectl --context="$c" -n "$APP_NS" get pods -o json 2>/dev/null \
      | jq -r '.items[]
               | select(.status.phase == "Running")
               | select([(.spec.containers[]?, .spec.initContainers[]?) | .name]
                        | index("linkerd-proxy") | not)
               | .metadata.name' 2>/dev/null || true)"
    total="$(echo "$bad" | grep -c . || true)"
    if [ "${total:-0}" -gt 0 ]; then
      die "'${src}' has ${total} pod(s) in ${APP_NS} running WITHOUT a proxy:
$(echo "$bad" | sed 's/^/       /')

     They serve plaintext and enforce no authorization policy, so any mTLS
     number from this run would describe them rather than the fault. This is
     the expected outcome of a previous recovery on PROFILE=default -- run
     'verify/meshed.sh --fix' and wait for it to settle before measuring."
    fi
  done
  ok "every ${APP_NS} pod across [$*] is meshed"
}

# Label the live sampler's output from here on.
#
# The Grafana timeline has been annotated at every fault boundary since the
# beginning (verify/annotate.sh) and the live viz feed has not, because
# `task viz:phase` existed and nothing ever called it. The consequence is not
# recoverable after the fact: the 2026-08-27 session produced 854 samples over
# 1.6 MB, every one of them phase="unknown", so the live feed cannot show where
# a fault began or ended. The replays were fine -- they are built from the
# baseline/during/recovered snapshots and are phase-keyed by construction --
# which is exactly why nobody noticed.
#
# Best-effort by design: no sampler running is the normal case for a one-off
# run, and a phase label is not worth failing an experiment over.
#
#   mark_phase <baseline|injected|converged|restored|...>
# Abort a run that is doing more damage than it predicted.
#
#   guard_blast_radius <observer> <mode> <cluster-that-should-survive>...
#
# "Minimize blast radius" is a chaos-engineering principle and this repo had no
# way to act on it: every runner injected a fault, slept, and reported whatever
# happened. If a fault took down a cluster it was not supposed to touch, the run
# continued to completion and the damage was only visible afterwards, mixed into
# the results.
#
# Called from the measurement window, this checks that the clusters the
# experiment is NOT targeting are still serving. If one has gone silent the
# fault escaped its intended domain, and continuing would both extend the damage
# and produce numbers about a fault nobody designed.
guard_blast_radius() {
  local src="$1" mode="$2" before="$3"; shift 3
  local c served
  for c in "$@"; do
    [ -n "$c" ] || continue
    served="$(_requests_to_cluster_from "$(proxy_responses "$src")" "$mode" "$c")"
    if [ "${served:-0}" -le "${before:-0}" ]; then
      warn "BLAST RADIUS: '${c}' was not targeted and has stopped serving
     (${served} requests, was above ${before}). The fault has escaped the domain
     it was meant to stay in. Aborting so the restore runs now rather than after
     another window of damage -- and so the results are not a description of a
     fault nobody designed."
      return 1
    fi
  done
  return 0
}

# Refuse to inject a fault on an instrument that has not been certified.
#
#   require_control_run
#
# fm0 injects nothing, measures everything and checks the instrument reads clean
# -- it is the only thing that separates a small real effect from measurement
# error, and it existed as a task nobody was obliged to run. Every instrument
# defect found this week was found because someone happened to run it.
#
# Certification is per-profile and time-boxed: a control run from a different
# profile, or from before the last rebuild, says nothing about this rig.
require_control_run() {
  local marker="${REPO_ROOT}/results/${PROFILE:-default}/fm0-control/during.metrics"
  local age
  if [ ! -f "$marker" ]; then
    die "no control run recorded for PROFILE=${PROFILE:-default}.
     Run 'task fm0' first. It injects nothing and certifies that the instrument
     reads clean -- without it a small real effect and a measurement error are
     indistinguishable, which is how this repo published 76%, 113% and 190%
     figures for services that were healthy."
  fi
  age=$(( $(now) - $(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || echo 0) ))
  if [ "$age" -gt "${CONTROL_MAX_AGE:-14400}" ]; then
    warn "the control run for PROFILE=${PROFILE:-default} is $(( age / 3600 ))h old.
     It certifies an instrument, and the rig has probably changed since. Re-run
     'task fm0' unless you know nothing has."
  else
    ok "instrument certified by a control run $(( age / 60 ))m ago"
  fi
}

# Sample the live mesh for the duration of ONE experiment.
#
# The phase hooks were called correctly for a whole session while nothing was
# sampling, so all 854 samples came out phase="unknown" and the live feed could
# not show where any fault began. A hook whose consumer is absent is
# indistinguishable from a broken hook.
#
# Scoped to the run rather than run as a daemon, because go-task kills its
# process group when a command returns -- a sampler started from a task does not
# survive it. A child of the runner does, for exactly as long as the runner
# lives, which is the window whose phases are worth recording.
sampler_start() {
  [ "${VIZ_SAMPLE:-1}" = "1" ] || return 0
  bash "${REPO_ROOT}/viz/export.sh" live >"${REPO_ROOT}/viz/data/sampler.log" 2>&1 &
  SAMPLER_PID=$!
  sleep 1
  if kill -0 "$SAMPLER_PID" 2>/dev/null; then
    ok "live sampler running (pid ${SAMPLER_PID}) -- phases will land in the feed"
  else
    SAMPLER_PID=""
    warn "live sampler did not start; replays are unaffected, the live feed will have no phases"
  fi
}

sampler_stop() {
  [ -n "${SAMPLER_PID:-}" ] || return 0
  kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
}

mark_phase() {
  bash "${REPO_ROOT}/viz/export.sh" phase "$1" >/dev/null 2>&1 || true

}

# Non-mTLS requests for a mode BETWEEN two snapshots.
#
# The mTLS checks used to read the cumulative value straight out of the `during`
# snapshot. Proxy counters never reset, so every run inherited the plaintext of
# every run before it, and the check failed on traffic that predated the
# experiment. On 2026-08-27 west was already carrying 1145 non-mTLS on the
# federated service and 2418 on the flat mirror -- all of it from the PREVIOUS
# experiment's recovery -- before FM2-hard had injected anything.
#
# This is the "cumulative counters are not a distribution" trap the repo
# documents for traffic distribution, sitting unfixed in the mTLS check. It
# probably contaminated two published findings (FM2-hard 2634, FM4 363).
#
# Delta, and refuse to invent a result if the counter went backwards.
#
#   nontls_delta <before-file> <after-file> <mode>
nontls_delta() {
  local before after mode="$3"
  # Per-series, for the same reason as everything else that deltas these
  # snapshots: a mode whose endpoints were removed loses series between them.
  mode_totals_delta "$1" "$2" "$mode" | awk '{print $3}'
}

# --- the client's own view ---------------------------------------------------
#
# Everything above reads the PROXY. That is the right primary source, but it
# cannot distinguish the repo's headline claim -- "the request hung in the
# balancer and never completed" -- from "the request was never issued". Both
# leave response_total untouched. k6 knows which happened, and until now nothing
# asked it: load/steady.js defines dr_requests and dr_errors and no code read
# them, so the central finding rested on the absence of evidence.
#
# k6's built-in REST API (enabled with --address in clusters/08-load.sh) reports
# live metric values. Read through kubectl exec, so it needs no Service.

# Raw JSON from a cluster's load generator. Empty if unavailable -- an older
# loadgen without --address must not break a run, it just cannot corroborate it.
k6_metrics() {
  kubectl --context="$(ctx "$1")" -n "$APP_NS" exec deploy/loadgen -c k6 -- \
    wget -qO- http://127.0.0.1:6565/v1/metrics 2>/dev/null || true
}

# One metric's value out of that JSON.
#   k6_metric_value "<json>" <metric-name> [count|value|rate]
# k6's JSON:API payload nests differently per metric type, so try the usual
# fields rather than assuming one shape.
k6_metric_value() {
  printf '%s' "$1" | python3 -c '
import json, sys
want = sys.argv[1]
field = sys.argv[2] if len(sys.argv) > 2 else "count"
try:
    doc = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
for item in doc.get("data", []):
    if item.get("id") != want:
        continue
    sample = item.get("attributes", {}).get("sample", {})
    for key in (field, "count", "value", "rate"):
        if key in sample:
            print(sample[key]); raise SystemExit
# k6 only creates a metric once it has a non-zero observation, so "absent" here
# means zero -- dropped_iterations does not exist until something is dropped.
# Returning "" put empty strings into shell arithmetic and broke the runners.
print(0)
' "$2" "${3:-count}" 2>/dev/null
}

# What the client actually experienced, as:
#   <attempted> <errors> <dropped_iterations> <timeouts>
#
# `dropped_iterations` is the one that matters for honesty about the numbers: it
# counts iterations k6 could not start because it ran out of VUs. Any figure
# expressed as a percentage of RPS x elapsed is wrong by exactly this much, and
# it rises precisely when requests hang.
k6_client_view() {
  local json
  json="$(k6_metrics "$1")"
  [ -n "$json" ] || { echo "- - - -"; return; }
  printf '%s %s %s %s\n' \
    "$(k6_metric_value "$json" dr_requests count)" \
    "$(k6_metric_value "$json" dr_errors count)" \
    "$(k6_metric_value "$json" dropped_iterations count)" \
    "$(k6_metric_value "$json" http_req_failed count)"
}

# Seconds since the epoch, for timing convergence.
now() { date +%s; }

# Record the CLUSTER TIER at this moment, one line per cluster: "<name> <nodes>".
#
# The status page's whole argument is the cluster tier staying green while the
# mesh tier degrades -- and on a recorded run that panel was blank, because
# nothing ever wrote node state down. Live runs had it; replays, which is how
# anyone reads a run afterwards, did not. So the page could not make its own
# point about the very runs it exists to show.
#
# Counted from `docker ps`, not kubectl, deliberately: during a partition the
# API server does not answer, and "kubectl failed" and "the nodes are gone" are
# very different claims. The containers are the ground truth for whether a node
# exists at all.
record_node_state() {
  local out="$1" name n
  : > "$out"
  for name in $(clusters); do
    n="$(docker ps --format '{{.Names}}' 2>/dev/null \
      | grep -cE "^k3d-${name}-(server|agent)-[0-9]+$" || true)"
    printf '%s %s\n' "$name" "${n:-0}" >> "$out"
  done
}
