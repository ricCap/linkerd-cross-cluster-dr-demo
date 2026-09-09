# Arm A — 2026-09-08

`PROFILE=default`, BEL `enterprise-2.20.1`, k3s `v1.33.6+k3s1`, 8 CPUs / 19.5 GB
Docker. Single-replica control plane, `failurePolicy=Ignore`.

**All six experiments pass.** This is the first sweep where every runner
completed green on one rig, and most of the day went on the instrument rather
than the mesh — which was the right ratio, because four of the seven defects
below would have produced confident, publishable, wrong numbers.

## Status

| | Experiment | Result |
|---|---|---|
| FM0 | control, no fault | **6/6** |
| FM1a | destination down | **4/4** |
| FM1b | identity down | **3/3** |
| FM1c | service-mirror down | **4/4** |
| FM2a | cluster loss, graceful | **6/6** |
| FM2b | cluster loss, hard partition | **6/6** |
| FM3 | zone brownout | **3/3** core + **3/3** modes |
| FM4 | region loss | **6/6** |

## What was measured

**FM0.** 100% of nominal on all three modes, 0 errors, 0 dropped iterations.
The floor every other number is read against.

**FM1a — discovery freezes and nothing says so.** With `linkerd-destination`
scaled to zero in `central`, the proxy's view held at **9 of 9 for the full 90s
window** while three backends no longer existed. Nothing alerted on the traffic
path.

**FM1b — the failover you planned requires identity.** Minimum certificate
headroom **22h17m**, measured rather than assumed. Scaling `app` 3 → 6 with
identity down **never reached 6**: the new pods sat at `Init:1/2`, because from
Kubernetes 1.29 the proxy is a native sidecar *init* container, so a pod that
cannot get a certificate never becomes ready. It does not crash-loop. It simply
never arrives, and nothing alerts on a pod that is merely still starting.

**FM1c — the service-mirror controllers do not own membership.** New
experiment. With every `controller-*` **and** `linkerd-local-service-mirror`
down in `central`, its destination view still tracked backends disappearing
(9 → 6 after 5s). `app-federated` has **no EndpointSlices** in that cluster:
destination resolves federated members across the Links at request time. The
controllers own the Service objects, not a cached copy of their endpoints.

**FM2a / FM2b — federation absorbs a cluster loss, both ways.** Zero errors
(0 of 2864 on the partition), 100% and 102% of expected throughput, zero
non-mTLS. Both non-federated controls collapsed to 1% of expected.

**FM4 — federation absorbs a region loss.** Both `region-a` clusters
partitioned simultaneously: **0 errors of 3876**, **100%** of expected absorbed
by the survivor, **0 non-mTLS**, **0 requests served by the dead region**, and
the observability stack answered **13/13** probes throughout.

**FM3 — HAZL reacts to degradation Kubernetes cannot see.** 800ms into one
zone across two of three clusters. Load peaked at **6.147 against a 6.00
threshold**, the active pool widened **3 → 4**, and **340 requests (11%)** moved
to remote-zone endpoints. Every pod stayed `Ready` and in its EndpointSlice
throughout; no Kubernetes condition changed at any point.

## The three-mode contrast, which no arithmetic touches

One fault, three outcomes, and they are not on a single spectrum:

- **federated** — keeps serving, on a view that may be stale
- **flat mirror** — collapses **silently**: near-zero throughput, clean error rate
- **gateway mirror** — fails **loudly**, thousands of 5xx

Under FM1 the gateway is the *only* mode that surfaces the fault. Under FM2 and
FM4 it is the worst performer. Same property, opposite sign, depending on which
way the fault points — and which one you get was decided by a label somebody set
months ago.

## Convergence timing is not measurable here, and that is the finding

Two runs of FM4, same fault, same rig: **34s** and **1s**.

`converge_by_traffic` times how long traffic to the dead clusters takes to stop.
HAZL concentrates traffic on a zone-local subset, so whether the partitioned
endpoints were carrying anything when the fault landed decides the answer —
east 104 / central 54 in the slow run, east 0 / central 0 in the fast one.

**No convergence number in this repo is a stable property of the fault on BEL**,
including FM2's 1s and 2s. This also retires the write-up's "13x difference
between a graceful stop and a partition": measured here, graceful 2s against
partition 1s. The *mechanism* is real; the magnitude belonged to
discovery-driven failover, and HAZL does not wait for discovery.

> On a load-aware balancer, failover cost depends on whether the balancer was
> using the thing you lost. **"How long is failover?" is the wrong question.
> "Was the lost capacity in the active set?" is the right one.**

## Instrument defects found and fixed

In order of how wrong the published number would have been.

1. **The throughput delta discarded the traffic the fault removed.** `mode_totals`
   summed whatever series a snapshot held, and the proxy evicts series for
   endpoints that no longer exist. FM2a was failed at **76%** on a run that was
   **100%**. Per-series now, keyed on the full label set.
2. **FM1's freeze check passed without measuring anything.** It asked the
   destination controller — which FM1a scales to zero. Nothing compared against
   nothing, and passed. The instrument now follows the fault.
3. **An unmeshed pod from one experiment contaminated the next.** FM4 baselined
   with **469** plaintext requests already on the counter, left by FM2b's
   recovery. `require_meshed` now gates every runner.
4. **FM1b silently degraded the rig for whatever ran next**, leaving pods
   stranded in `Init:1/2` while restoring the replica count. FM3 then ran against
   a pool of 7.
5. **The remedy reproduced the fault.** `meshed.sh --fix` restarted once, and the
   restart races the injector again. Retries three times now, and says plainly
   that under `failurePolicy=Ignore` it cannot guarantee injection.
6. **FM3's cleanup could not fail**, so it did not: Chaos Mesh finalizers blocked
   deletion and one run hung **30 minutes with the brownout still applied**.
   Bounded, with a finalizer fallback.
7. **FM1's denominator used the nominal window**, reporting **113%** for traffic
   that was exactly nominal — biased upward, which masks a shortfall. Now
   elapsed time. Reads 100%.

Two further constraints discovered by hitting them:

**The brownout has a ceiling.** At 900ms, proxies in the slowed zone could not
start — `connect timed out after 1s` to `linkerd-policy`, startup probes
failing, pods stranded in `Init:1/2` across two clusters. Past the proxy's own
control-plane timeout the experiment stops measuring a slow zone and starts
measuring whether the mesh can come up. Capped at 800ms.

**The load-crossing check cannot be a gate.** Peak load across sized runs:
500ms → 4.697, 750ms → 5.764, 900ms → 5.751. It asymptotes below the threshold
because shedding the slow endpoints lowers throughput through them, and load is
latency × throughput — **the metric self-limits as the mechanism under test
reacts.** Reported now, not asserted; the passing run caught a crossing at
6.147, confirming sampling luck rather than an undersized fault.

## Not run

- **`PROFILE=production`** — the HA arm. Every claim here about control-plane
  outage severity and about unmeshed pods belongs to the defaults.
- **FM5** — the trust anchor, the only failure domain with no failover target.
- **Repeat runs.** Everything here is n=1 except FM4, and FM4's two runs are
  exactly why that matters.
