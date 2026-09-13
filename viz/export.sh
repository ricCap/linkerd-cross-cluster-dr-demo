#!/usr/bin/env bash
# Turn the mesh's live state into a snapshot feed the viewer can render.
#
#   viz/export.sh once                 one sample to stdout
#   viz/export.sh live [file]          append a sample every $INTERVAL seconds
#   viz/export.sh replay <results-dir> keyframes from a recorded experiment
#   viz/export.sh phase <name>         label the samples that follow
#
# One line of JSON per sample (NDJSON). This is the ONLY thing in viz/ that
# touches a cluster; the page itself just reads the feed.
#
# RATES, NOT COUNTERS
#
# Proxy counters are cumulative, and verify/lib.sh already documents where that
# bites: during an outage the raw distribution still shows a large count for the
# dead cluster -- all of it banked before the fault -- which reads as "the dead
# cluster is still serving traffic", exactly backwards. A chart animating those
# numbers would state it in colour, at ten frames a second.
#
# So a sample carries the DELTA since the previous one and never a total.
# Deltas are per series, keyed on the full label set, and taken only over series
# present in both dumps. That is the fix for the bug that produced
# `app-flat-east -5381 reqs` in results/run-2026-08-17/SUMMARY.md: when a deployment
# restarts, the proxy holds the old pods' series for a while and then evicts
# them, so summing whatever exists in each snapshot subtracts a population that
# is no longer there. Keying on labels makes an evicted series simply absent
# rather than negative.
#
# A series present now and absent before is counted in FULL. A proxy series is
# created by its first matching response, so it starts at zero inside the window
# -- ordinary counter semantics, and what `rate()` does with a new series.
# Dropping it instead under-reports exactly where it hurts most: after a
# recovery every pod is new, so a restored cluster would read as serving
# nothing while it is in fact serving. The one case where full-counting is wrong
# is the FIRST sample of a session, where every series is new but its counter
# holds the whole proxy uptime. That sample is marked `warmup` and reports zero.

. "$(dirname "${BASH_SOURCE[0]}")/../verify/lib.sh"

need linkerd docker

now_f() {
  perl -MTime::HiRes -e 'printf "%.3f", Time::HiRes::time()' 2>/dev/null || now
}

INTERVAL="${INTERVAL:-5}"
STATE="${STATE:-${REPO_ROOT}/viz/data}"
OBSERVER_EXPLICIT="${OBSERVER:+1}"
OBSERVER="${OBSERVER:-west}"
mkdir -p "$STATE"

# --- topology, as awk-friendly strings --------------------------------------

# "10.21.=west,10.22.=east,..." -- the pod-CIDR half of cluster_of_ip.
pod_prefixes() {
  local c out=""
  for c in $(clusters); do
    out="${out}$(cluster_pod_cidr "$c" | cut -d. -f1,2).=${c},"
  done
  echo "${out%,}"
}

# "172.28.0.7=east,..." -- the node-address half. Gateway mirrors resolve to a
# node address because klipper-lb publishes those for the gateway Service, so
# without this every gateway-mode request files under "other".
# Which node table to attribute against. Live sampling uses the rig's current
# one; a replay uses the table recorded WITH the run, and none if the run did
# not record one.
#
# Using today's table on an old recording would be silently wrong: node
# addresses are assigned by Docker and change across rebuilds, so a 172.28.0.7
# that was east last week can be central today. That produces a confident,
# plausible, wrong attribution -- strictly worse than admitting the gateway
# endpoints cannot be placed.
NODE_TABLE="${NODE_TABLE:-$(ip_state_file)}"

node_addresses() {
  local f out="" n ip c
  f="$NODE_TABLE"
  [ -f "$f" ] || { echo ""; return; }
  while read -r n ip; do
    [ -n "${ip:-}" ] || continue
    c="$(echo "$n" | sed -E 's/^k3d-//; s/-(server|agent)-[0-9]+$//')"
    out="${out}${ip}=${c},"
  done < "$f"
  echo "${out%,}"
}

# Is the node table available at all? Without it a gateway mirror's endpoint --
# a node address, not a pod IP -- cannot be attributed to a cluster and lands in
# "other". That is the documented fallback rather than a failure, but the viewer
# has to be able to tell "went somewhere unexpected" from "cannot tell yet".
have_node_table() { [ -f "$NODE_TABLE" ] && echo true || echo false; }

# "federated=app-federated,flat=app-flat-east,gateway=app-gateway-east-gw"
# The gateway row is absent where the cluster carries no gateway link, and that
# absence is meaningful: see modes_for in clusters/lib.sh.
mode_map() {
  modes_for "$1" | awk '{ printf "%s%s=%s", (NR>1 ? "," : ""), $1, $2 } END { print "" }'
}

# --- the parser -------------------------------------------------------------
#
# ONE implementation, shared by the live and replay paths. They differ only in
# where the two dumps come from: live diffs against the previous tick, replay
# diffs against a recorded baseline. Keeping them on one code path means the
# replay tests -- which run without a cluster -- exercise what live ships.
#
#   metrics_json <src> <prevfile> <nodes> < current-dump
#
# `nodes` is the running node count, or "" when it is not known (a recorded run
# never wrote one down, and guessing it from traffic is how plausible fiction
# gets into a results table).
metrics_json() {
  awk \
    -v src="$1" \
    -v prevfile="$2" \
    -v nodes="$3" \
    -v modes="$(mode_map "$1")" \
    -v prefixes="$PREFIXES" \
    -v naddrs="$NADDRS" '
  function jnum(x) { return (x == "" ? "null" : x) }

  # Which cluster owns an endpoint address: pod CIDR first, then the node table.
  function cluster_of(ip,   i) {
    for (i = 1; i <= npfx; i++) if (index(ip, pfx[i]) == 1) return pfxc[i]
    if (ip in node2c) return node2c[ip]
    return "other"
  }

  function label(line, name,   s, n) {
    n = name "=\""
    if (!match(line, n "[^\"]*\"")) return ""
    return substr(line, RSTART + length(n), RLENGTH - length(n) - 1)
  }

  # Everything but the trailing value. Computed rather than taken as $1 so a
  # label containing a space could not silently split the key.
  function keyof(line) { return substr(line, 1, length(line) - length($NF) - 1) }

  BEGIN {
    n = split(modes, a, ",")
    for (i = 1; i <= n; i++) {
      split(a[i], kv, "=")
      modeof[kv[2]] = kv[1]       # service name -> abstract mode
      svcof[kv[1]]  = kv[2]
      order[++nmodes] = kv[1]
    }
    n = split(prefixes, a, ",")
    for (i = 1; i <= n; i++) { split(a[i], kv, "="); pfx[++npfx] = kv[1]; pfxc[npfx] = kv[2] }
    n = split(naddrs, a, ",")
    for (i = 1; i <= n; i++) { split(a[i], kv, "="); if (kv[1] != "") node2c[kv[1]] = kv[2] }

    # The previous dump, in the same format as the current one.
    while ((getline line < prevfile) > 0) {
      if (line !~ /^response_total\{/) continue
      nf = split(line, fld, " ")
      prev[substr(line, 1, length(line) - length(fld[nf]) - 1)] = fld[nf] + 0
      havePrev = 1
    }
    close(prevfile)
  }

  /^response_total\{/ {
    v = $NF + 0
    key = keyof($0)

    auth = label($0, "authority")
    if (auth == "") next
    svc = auth; sub(/\..*/, "", svc)
    m = modeof[svc]
    if (m == "") next            # some other authority; not one of our modes

    if (key in prev) {
      d = v - prev[key]
      # A proxy restart zeroes its counters. Clamp rather than emit a negative
      # rate, and surface the count so a suspicious chart can be explained.
      if (d < 0) { resets++; d = 0 }
    } else {
      d = (havePrev ? v : 0)
    }
    if (d == 0) next

    reqs[m] += d
    if (label($0, "status_code") !~ /^2/) errs[m] += d
    if (label($0, "tls") != "true")       ntls[m] += d
    c = cluster_of(label($0, "target_ip"))
    dist[m SUBSEP c] += d
    seen[c] = 1
  }

  # Balancer gauges, out of the same dump. parent_name is the service, so these
  # attach to a mode the same way response_total does. Absent from recorded
  # snapshots, which record response_total only -- hence null rather than zero.
  /^outbound_http_balancer_/ {
    m = modeof[label($0, "parent_name")]
    if (m == "") next
    if ($0 ~ /^outbound_http_balancer_adaptive_endpoints\{/)    adaptive[m] = $NF + 0
    else if ($0 ~ /^outbound_http_balancer_endpoints\{endpoint_state="ready"/) ready[m] = $NF + 0
    else if ($0 ~ /^outbound_http_balancer_adaptive_load_average\{/)   load[m] = $NF + 0
    else if ($0 ~ /^outbound_http_balancer_adaptive_load_band_low\{/)  lo[m]   = $NF + 0
    else if ($0 ~ /^outbound_http_balancer_adaptive_load_band_high\{/) hi[m]   = $NF + 0
  }

  END {
    printf "\"%s\":{\"status\":\"up\",", src
    if (nodes != "") printf "\"nodes\":%s,", nodes
    printf "\"warmup\":%s,\"resets\":%d,\"modes\":{", (havePrev ? "false" : "true"), resets + 0
    for (i = 1; i <= nmodes; i++) {
      m = order[i]
      printf "%s\"%s\":{\"svc\":\"%s\",", (i > 1 ? "," : ""), m, svcof[m]
      printf "\"reqs\":%d,\"errors\":%d,\"nontls\":%d,\"dist\":{", reqs[m]+0, errs[m]+0, ntls[m]+0
      first = 1
      for (c in seen) {
        if (dist[m SUBSEP c] == "") continue
        printf "%s\"%s\":%d", (first ? "" : ","), c, dist[m SUBSEP c]
        first = 0
      }
      # pool: what discovery believes exists. active: what the balancer is using.
      # The same number on OSS and deliberately different under HAZL -- see the
      # note on endpoint_pool in verify/lib.sh.
      printf "},\"pool\":%s,\"active\":%s,\"load\":%s,\"band\":[%s,%s]}",
        jnum(adaptive[m] != "" ? adaptive[m] : ready[m]),
        jnum(ready[m]), jnum(load[m]), jnum(lo[m]), jnum(hi[m])
    }
    printf "}}"
  }' -
}

# --- liveness ---------------------------------------------------------------
#
# Three states, not two, because the difference is the whole point of FM2's two
# variants. A graceful `docker stop` leaves no running container; a hard
# partition leaves every container running and unreachable. Collapsing them into
# "down" throws away the distinction the experiment exists to draw.
#
#   up           metrics answered
#   unreachable  nodes running, metrics did not answer
#   down         no nodes running
running_nodes() {
  docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -cE "^k3d-${1}-(server|agent)-[0-9]+$" || true
}

# proxy-metrics against a cluster that is up but wedged does not fail, it hangs.
# Measured at ~30s against a cluster whose load generator had come back without
# a proxy -- which stretches every tick to 30s, for all three clusters, because
# one of them is in trouble. A sampler that slows down exactly when something
# breaks is worse than useless.
#
# macOS has no `timeout`, hence the watchdog.
FETCH_TIMEOUT="${FETCH_TIMEOUT:-6}"

fetch_metrics() {
  local src="$1" out="$2" pid wd
  : > "$out"
  ( linkerd --context="$(ctx "$src")" diagnostics proxy-metrics \
      -n "$APP_NS" deploy/loadgen >"$out" 2>/dev/null ) &
  pid=$!
  ( sleep "$FETCH_TIMEOUT"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" >/dev/null 2>&1 || true
  kill -TERM "$wd" >/dev/null 2>&1 || true
  wait "$wd" >/dev/null 2>&1 || true
}

# The flavor of the RIG, not of the shell that happened to start the sampler.
#
# viz/build.sh was fixed on 2026-08-27 after publishing seven BEL runs labelled
# OSS -- it now reads a per-run `flavor` file. The LIVE feed kept taking it from
# $LINKERD_FLAVOR, so a sampler started without that variable exported labelled
# a BEL rig as OSS on the page header. Same defect, different code path, and it
# matters for the same reason: endpoints{ready} means the whole pool on OSS and
# HAZL's active subset on BEL, so the label decides how every endpoint number on
# the page should be read.
#
# The enterprise control plane ships a `linkerd-enterprise` deployment that OSS
# does not, so ask the cluster.
detect_flavor() {
  local src="${1:-$(clusters | head -1)}"
  if kubectl --context="$(ctx "$src")" -n linkerd get deploy linkerd-enterprise \
       >/dev/null 2>&1; then
    echo bel
  elif kubectl --context="$(ctx "$src")" -n linkerd get deploy linkerd-destination \
       >/dev/null 2>&1; then
    echo oss
  else
    echo unknown
  fi
}

# Why did a cluster give us nothing?
#
# "unreachable" is the wrong answer for the most interesting case in this whole
# repo. A cluster can come back from a restart with every workload Running,
# Ready, and OUTSIDE the mesh -- pods admitted while the proxy-injector was
# unavailable never get a proxy, and nothing retries. No proxy means no proxy
# metrics, so the sampler sees silence from a cluster that is in perfect health
# at the cluster tier.
#
# Reporting that as "unreachable" tells the operator the opposite of the truth:
# it reads as an outage when what actually happened is that the cluster is up
# and quietly unencrypted. Distinguishing the two is most of the point of
# putting this on a screen.
#
# Only run when metrics came back empty -- probe the cause when there is a
# symptom, not on every tick.
diagnose_silence() {
  local src="$1" nodes="$2" containers
  [ "$nodes" -eq 0 ] && { echo down; return; }

  # Ask the API whether it is there, BEFORE inferring anything from the load
  # generator.
  #
  # This used to read "no loadgen pod" as "unreachable", which was right when a
  # generator ran in every cluster and became wrong the moment LOAD_CLUSTERS was
  # narrowed to west alone (see SHORTCOMINGS 14 -- co-located generators meant a
  # fault removed demand at the same instant it removed supply). After that
  # change, east and central have no generator BY DESIGN, and the status page
  # reported two perfectly healthy clusters as partitioned.
  #
  # Which is precisely what the note above this function warns against:
  # reporting silence as an outage "tells the operator the opposite of the
  # truth". It did, for every run on this page.
  if ! kubectl --context="$(ctx "$src")" get --raw='/readyz' >/dev/null 2>&1; then
    echo unreachable          # the API genuinely did not answer
    return
  fi

  containers="$(kubectl --context="$(ctx "$src")" -n "$APP_NS" \
    get pods -l app=loadgen -o jsonpath='{.items[*].spec.containers[*].name}' 2>/dev/null || true)"

  if [ -z "$containers" ]; then
    # API is up and this cluster simply does not generate load. Not a fault.
    echo no-generator
  elif ! echo "$containers" | grep -q linkerd-proxy; then
    echo unmeshed             # Running, Ready, and outside the mesh
  else
    echo silent               # proxy is there and is not answering
  fi
}

# Deliberately ONE proxy-metrics call per cluster: response_total and the
# balancer gauges come out of the same dump. watch.sh makes a second call per
# cluster for the endpoint pool, which is affordable at a 5s refresh a human is
# reading and not at the rate a chart wants.
fetch_all() {
  local src pids="" p
  for src in $(clusters); do
    fetch_metrics "$src" "${STATE}/${src}.raw" &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p" >/dev/null 2>&1 || true; done
}

sample_source() {
  local src="$1" raw prev nodes status
  prev="${STATE}/${src}.prev"
  nodes="$(running_nodes "$src")"
  raw="$(cat "${STATE}/${src}.raw" 2>/dev/null || true)"

  if [ -z "$raw" ]; then
    # Do NOT clear the prev dump. The cluster comes back at some point and its
    # counters come back with it; keeping the baseline means the first sample
    # after recovery is a real delta rather than a dropped interval.
    status="$(diagnose_silence "$src" "$nodes")"
    printf '"%s":{"status":"%s","nodes":%s,"modes":{}}' "$src" "$status" "$nodes"
    return
  fi

  [ -f "$prev" ] || : > "$prev"
  printf '%s\n' "$raw" | metrics_json "$src" "$prev" "$nodes"
  printf '%s\n' "$raw" > "$prev"
}

# --- samples ----------------------------------------------------------------

# The rig itself: cluster table and zone list, straight from clusters/lib.sh.
# Shipped with every sample so the viewer never hardcodes a picture of a
# topology that table is the source of truth for.
topology_json() {
  local src first=1
  printf '"topology":['
  for src in $(clusters); do
    [ "$first" = 1 ] || printf ','
    printf '{"name":"%s","region":"%s","pod_cidr":"%s"}' \
      "$src" "$(cluster_region "$src")" "$(cluster_pod_cidr "$src")"
    first=0
  done
  printf '],"zones":['
  first=1
  for src in $(all_zones); do
    [ "$first" = 1 ] || printf ','
    printf '"%s"' "$src"
    first=0
  done

  # The app, not just the rig. Which workload backs each exposure mode and which
  # clusters it actually runs in -- app-gateway lives in east alone, which is why
  # the gateway lane always points there.
  local w mode reps scope c inner
  printf '],"workloads":['
  first=1
  for w in $(workloads); do
    [ "$first" = 1 ] || printf ','
    mode="$(workload_field "$w" 2)"
    reps="$(workload_field "$w" 3)"
    # Read the scope directly rather than grepping workloads_in.
    #
    # `workloads_in "$c" | grep -q ...` reads correctly and behaves erratically:
    # grep -q exits at the first match, closing the pipe while workloads_in is
    # still writing, and pipefail turns that SIGPIPE into a 141. It is the same
    # trap verify/lib.sh documents against the linkerd CLI, and it presented
    # here as app appearing in no clusters at all.
    scope="$(workload_field "$w" 6)"
    inner=""
    for c in $(clusters); do
      if [ "$scope" = "all" ] || [ "$scope" = "$c" ]; then inner="${inner}\"${c}\","; fi
    done
    printf '{"name":"%s","mode":"%s","replicas":%s,"clusters":[%s]}' \
      "$w" "$mode" "$reps" "${inner%,}"
    first=0
  done

  printf '],"gateways":['
  first=1
  for c in $(gateway_hosts); do
    [ "$first" = 1 ] || printf ','
    printf '"%s"' "$c"
    first=0
  done
  printf ']'
}

emit_sample() {
  local src first=1 phase t last window
  phase="$(cat "${STATE}/phase" 2>/dev/null || echo unknown)"
  PREFIXES="$(pod_prefixes)"; NADDRS="$(node_addresses)"

  # ACTUAL elapsed time since the last sample, not the nominal interval, and to
  # sub-second precision.
  #
  # A tick is `sleep $INTERVAL` plus however long the sampling itself took --
  # three `linkerd diagnostics proxy-metrics` calls, about a second in total.
  # Dividing a 5.9s window of requests by a nominal 5 reports 34 rps against a
  # load generator configured for 30, and every rate on the page inherits the
  # same ~18% inflation.
  #
  # Whole seconds are not good enough either: rounding that same 5.9s window to
  # 6 reports 28.7. At a 5s tick, one second of quantisation is a 17% error --
  # the correction and the error are the same size.
  #
  # Both look like plausible numbers, which is what makes them dangerous.
  # Nothing errors and the shape of the traffic is right; the only thing that
  # catches it is checking a total against the configured RPS.
  t="$(now_f)"
  last="$(cat "${STATE}/last-t" 2>/dev/null || echo 0)"
  window="$(awk -v a="$t" -v b="$last" -v i="$INTERVAL" \
    'BEGIN { d = a - b; if (b > 0 && d > 0) printf "%.2f", d; else printf "%s", i }')"
  echo "$t" > "${STATE}/last-t"

  printf '{"t":%s,"iso":"%s","interval":%s,"window":%s,"phase":"%s","flavor":"%s","observer":"%s","node_table":%s,' \
    "${t%.*}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$INTERVAL" "$window" "$phase" "${RIG_FLAVOR:-unknown}" \
    "$OBSERVER" "$(have_node_table)"
  topology_json
  printf ',"sources":{'
  fetch_all
  for src in $(clusters); do
    [ "$first" = 1 ] || printf ','
    sample_source "$src"
    first=0
  done
  printf '}}\n'
}

# --- replay -----------------------------------------------------------------
#
# Recorded runs hold three snapshots -- baseline, during, recovered -- so this
# produces three keyframes, not a timeline, and says `keyframe` in every one so
# the viewer can label it honestly rather than implying an interpolation it
# never measured.
#
# The snapshots carry no timestamps, so window length comes from file mtime.
# That is the real wall-clock spacing of the run.
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

replay() {
  local dir="$1" f label prev="" run obs window
  [ -d "$dir" ] || die "no such results directory: ${dir}"
  run="$(basename "$dir")"

  # The run's own node table, or none. Runs recorded before the runners started
  # saving it attribute gateway endpoints to "other", which the page reports as
  # unknown attribution rather than an unknown destination.
  NODE_TABLE="${dir}/node-ips.txt"
  PREFIXES="$(pod_prefixes)"; NADDRS="$(node_addresses)"

  # Which cluster's proxy produced these snapshots. The runners disagree on
  # purpose -- FM1 reads the cluster whose control plane it breaks, the others
  # read a surviving observer -- so this is recorded rather than assumed.
  # Guessing it is silently wrong: mirror service names differ per cluster, so
  # the wrong observer measures a service that was never exercised and reports
  # it as zero traffic, which is indistinguishable from a mode that died.
  if [ -f "${dir}/observer" ]; then
    obs="$(cat "${dir}/observer")"
  elif [ -n "${OBSERVER_EXPLICIT:-}" ]; then
    obs="$OBSERVER"
  else
    die "${dir} has no 'observer' file, so which cluster it was recorded from is
unknown. Runs made before the runners started recording it need it supplied:

  OBSERVER=<cluster> task viz:replay RUN=${run}

fm1 records from its TARGET (default 'central'); fm2, fm3 and fm4 record from
OBSERVER (default 'west')."
  fi
  OBSERVER="$obs"

  # Flavor travels with the run, exactly as the observer does. The page reads it
  # off each sample, so a replay without it renders "—" and the reader has no way
  # to know whether endpoints{ready} means the whole pool (OSS) or HAZL's active
  # subset (BEL). "unknown" is honest; the shell's own $LINKERD_FLAVOR would be a
  # confident guess about a run that may have happened days ago.
  run_flavor="$(cat "${dir}/flavor" 2>/dev/null || echo unknown)"

  for label in baseline during recovered; do
    f="${dir}/${label}.metrics"
    [ -f "$f" ] || continue

    printf '{"t":%s,"phase":"%s","run":"%s","observer":"%s","flavor":"%s","node_table":%s,"keyframe":true' \
      "$(mtime_of "$f")" "$label" "$run" "$OBSERVER" "$run_flavor" "$(have_node_table)"

    # Cluster tier for THIS phase, if the run recorded it.
    #
    # This panel is the argument the page exists to make -- the cluster tier
    # staying green while the mesh tier degrades -- and on replays it was blank,
    # because nothing wrote node state down. Runs recorded before
    # `record_node_state` existed still render "not recorded", which is honest;
    # runs recorded after it show the contrast.
    nodes_file="${dir}/${label}.nodes"
    obs_nodes=""
    [ -f "$nodes_file" ] && obs_nodes="$(awk -v c="$OBSERVER" '$1 == c { print $2 }' "$nodes_file")"

    # Every cluster except the observer, node count only: a recorded run holds
    # the observer's proxy metrics and nothing else, so claiming anything about
    # the others' mesh state would be invention. Node existence we do know.
    other_sources() {
      local name n
      [ -f "$nodes_file" ] || return 0
      while read -r name n; do
        [ -n "$name" ] || continue
        [ "$name" != "$OBSERVER" ] || continue
        printf ',"%s":{"nodes":%s,"modes":{}}' "$name" "$n"
      done < "$nodes_file"
    }

    if [ -z "$prev" ]; then
      # Nothing to diff the first keyframe against, so it is a marker rather
      # than a measurement -- no invented rates. Node state is not a rate, so it
      # can be reported here.
      printf ','; topology_json; printf ',"sources":{'
      if [ -n "$obs_nodes" ]; then
        printf '"%s":{"nodes":%s,"modes":{}}' "$OBSERVER" "$obs_nodes"
        other_sources
      fi
      printf '}}\n'
    else
      # Refuse a non-positive window rather than dividing by it.
      #
      # The window is mtime(this) - mtime(previous), and nothing guarantees the
      # snapshots were written in phase order: a re-copied or re-touched
      # baseline makes `during` look 295 seconds older than the run that
      # produced it. That is not a near-miss. Every rate divides by this
      # number, so a negative window turns a healthy 30 rps into -0.0 across
      # every mode -- which the page draws as a total outage, and which is the
      # exact inversion `Zero is not the same as dead` exists to prevent.
      #
      # It already published one run that way (production-fm3), so this is a
      # hard stop, not a warning: an unusable keyframe must not reach the site
      # looking like a result.
      window="$(( $(mtime_of "$f") - $(mtime_of "$prev") ))"
      [ "$window" -gt 0 ] || die "${run}: snapshot '$(basename "$f")' has mtime
${window}s relative to '$(basename "$prev")', so its window is not positive and
every rate derived from it would be wrong.

Snapshot mtimes are the only record of a replay's timing, so this cannot be
recomputed -- the run has to be re-recorded, or dropped."
      printf ',"window":%s,' "$window"
      topology_json
      printf ',"sources":{'
      metrics_json "$OBSERVER" "$prev" "$obs_nodes" < "$f"
      other_sources
      printf '}}\n'
    fi
    prev="$f"
  done
}

# --- entry points -----------------------------------------------------------

case "${1:-once}" in
  once)
    emit_sample
    ;;

  live)
    out="${2:-${STATE}/live.ndjson}"
    : > "$out"
    # Drop stale dumps: a feed that starts mid-run would otherwise report its
    # first interval as everything accumulated since the last session.
    rm -f "${STATE}"/*.prev "${STATE}/last-t"
    RIG_FLAVOR="$(detect_flavor)"
    log "sampling every ${INTERVAL}s into ${out}  (flavor: ${RIG_FLAVOR}, read from the rig)"
    trap 'exit 0' INT TERM
    while true; do
      # Build the whole line, then append it in ONE write.
      #
      # emit_sample printf's incrementally, so appending it directly lets a
      # reader catch the file mid-sample and see a truncated object. The page
      # tolerates that -- it skips unparseable lines -- but a sample silently
      # dropped from a live chart is a gap nobody can explain afterwards, and a
      # single append of a few KB does not tear.
      line="$(emit_sample)"
      printf '%s\n' "$line" >> "$out"
      sleep "$INTERVAL"
    done
    ;;

  replay)
    [ -n "${2:-}" ] || die "usage: viz/export.sh replay <results-dir>"
    replay "$2"
    ;;

  phase)
    [ -n "${2:-}" ] || die "usage: viz/export.sh phase <name>"
    echo "$2" > "${STATE}/phase"
    ;;

  *)
    die "usage: viz/export.sh <once|live|replay <dir>|phase <name>>"
    ;;
esac
