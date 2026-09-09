# Run report — 2026-08-17, BEL, post-renumbering

First full run after two harness changes: the FM renumbering (control plane →
cluster → zone → region) and the region swap that moved `west` out of every
experiment's blast radius.

Environment in `ENVIRONMENT.txt`. Raw proxy metric snapshots in `../fm*/`;
cleaned experiment logs in `logs/`.

**One-line verdict:** three experiments produced publishable results, the
observability fix is confirmed working, and four measurement bugs were found —
two of which are findings in their own right.

---

## Results

| Run | Checks | Verdict |
|---|---|---|
| fm1-destination | 1/1 | **clean** |
| fm1-identity | 2/2 | **clean** |
| fm2-graceful | 6/6 | **clean** |
| fm2-hard | 5/6 | throughput figures unusable (bug 1) |
| fm3-zone | 1/3, twice | fault under-powered (bug 4) |
| fm4-region | 4/6 | observability checks valid; throughput unusable |

### Publishable

**FM1a — destination controller down.** Pool still 9 after 90s with 3 pods
actually gone, 0 errors. Discovery frozen, traffic unaffected. Confirms the
existing finding on a clean BEL environment.

**FM1b — identity down.** Certificate headroom **23h52m** (prior run: 23h50m).
Existing traffic 113% of expected over 90s. Scale-up 3→6 **blocked**, never
reached 6 in 120s. Confirms the sharpest result in the set.

**FM2 graceful — all six checks pass.** Detection **0s**, 0 federated errors,
100% throughput held, flat mirror collapsed to 1%, gateway mirror to 4% with 121
errors, **0 non-mTLS**. This is the only run of the day with a completely clean
baseline (no preceding remesh), so its throughput numbers are the trustworthy
ones.

### The observability fix, confirmed

```
ok observability stack is in 'west', outside region 'region-a'
ok dashboard reachable before injection
observability stack survived the region loss   PASS  13/13 probes
```

The preflight guard fired correctly, and the dashboard stayed up through the
entire regional failure — the accidental finding is now a measured check.

Other valid FM4 numbers (these do not depend on the broken delta arithmetic):

| Measure | Result |
|---|---|
| Surviving region absorbs traffic | **97%** of expected |
| Federated errors | 65 of 7133 (**0.9%**) |
| Traffic served by the dead region | 48 reqs, pre-convergence only |
| Recovery to 9 endpoints | **261s** |

---

## Bugs found, in order of how much they matter

### 1. Delta arithmetic breaks when endpoints churn — *affects every throughput number*

`mode_totals` in `verify/lib.sh` sums whatever `response_total` series exist in a
snapshot. When a deployment restarts, the proxy holds the old pods' counters for
a while and then evicts them. If the baseline snapshot contains series that are
gone by the "during" snapshot, the delta goes **negative**.

Observed in fm4: `api-east  -5381 reqs (-73% of expected)`.

Proof — same authority, same series count (8), different series:

```
baseline:  target_ip=10.22.2.59  dst_pod=api-6b7d84d966-ljvc4  count=5421
during:    (absent)              dst_pod=api-5645bb58d4-…
```

Different ReplicaSet hashes. The counters did not go backwards; the *population*
changed underneath the sum.

**Fix:** delta only over series present in both snapshots, keyed on the full
label set — or at minimum clamp at zero and warn. Note this is a close cousin of
the already-documented "cumulative counters are not a distribution" trap, and it
deserves a place beside it in FINDINGS.

### 2. Remeshing immediately before an experiment poisons its baseline

Introduced by this run's own driver (`drivers/run-rest.sh`), which remeshes
between experiments so the next one starts from a fully meshed cluster. That
remesh restarts deployments, which is precisely what creates the doomed counter
series in bug 1.

**Fix:** after a remesh, wait for stale series to age out before snapshotting a
baseline. The remesh itself is still right — the alternative is measuring a
half-plaintext mesh — it just needs a settle window.

### 3. `endpoint_pool` measures different things on OSS and BEL — *possible false FAIL*

`membership converges 9 → 3` **FAILED, not within 120s**, against 90s in the
prior OSS run. Recovery afterwards took 261s.

`verify/metrics.md` already documents that `adaptive_endpoints` (BEL) is
"endpoints available" while `endpoints{ready}` on OSS is the whole pool, and
that under HAZL `endpoints{ready}` is instead the *active subset*.
`verify/lib.sh` prefers `adaptive_endpoints` when present. So the convergence
check may be asserting on availability rather than membership, and the 120s
timeout may be measuring the wrong series rather than a real regression.

**Resolve before publishing any BEL convergence figure.** The OSS 6s / 82s / 90s
progression should not be mixed with BEL numbers until this is settled.

### 4. FM3's injected fault is too weak for the band it now faces

Two runs, same outcome: peak load **7.846** and **7.895**, threshold **8.00**,
never crossed.

`chaos/fm3-zone-brownout.sh` derives its 400ms default from a **6.0** threshold
at 30 rps. But the band scales with the active pool, and the baseline active
pool in this environment is **4**, not the 3 recorded in FINDINGS — so the band
is `[3.20 .. 8.00]`, and 400ms lands just short.

HAZL still demonstrably reacted (pool widened 4 → 5), so the mechanism holds;
the *assertion* is mis-calibrated. Worth understanding **why the baseline moved
from 3 to 4** before simply raising the latency — the region relabelling is the
obvious suspect and, if it changed HAZL's locality maths, that is itself worth
reporting.

This is the harness being bitten by the exact trap FINDINGS documents: *do not
assume the band, read it.*

---

## Corrections to existing documents

### SHORTCOMINGS §4 is falsified

It claims the address-pinning fix eliminated unmeshed-pod recovery:

> "no pods came back unmeshed — the injector churn that caused that was itself a
> consequence of the address drift"

**It reproduced twice out of two hard-partition restores**, on BEL, with
addresses pinned and no cluster cycle. Evidence, from east after the first
restore — four pods with *no init containers at all* while their siblings in the
same ReplicaSet have both:

| Pod | Created | Init containers |
|---|---|---|
| `frontend-…-5pvm7` | 15:10:**40** | `<none>` |
| `frontend-…-wfv2c` | 15:10:**53** | `linkerd-init, linkerd-proxy` |
| `frontend-…-jljtk` | 15:10:**59** | `linkerd-init, linkerd-proxy` |

One per deployment — `frontend`, `api`, `analytics`, **and `loadgen`**. The pods
created 13–19 seconds earlier lost the race with the proxy injector.

This is good news for the post: the mechanism is independent of the k3d address
artifact, so the headline finding stands on its own.

### One `--fix` pass is not enough

`verify/meshed.sh --fix` restarts the affected deployments — and those restarts
race the injector too. The first pass found 3 unmeshed pods and left 4. The
driver now loops until `meshed.sh` is clean; that should move into `meshed.sh`
itself.

### mTLS failures are a *recovery* phenomenon, not a failover one

Both fm2-hard (2634 non-mTLS) and fm4 (363 non-mTLS) failed the mTLS check, and
in both cases the plaintext appears during the **restore**, not during the
outage. Federated traffic held through the partition with zero errors.

"mTLS survives failover" is intact. The sharper claim the data supports is
**mTLS breaks during recovery** — which is more useful, and consistent with the
unmeshed-pod mechanism above.

### The mTLS dashboard panel is a trailing indicator

Measured across windows during a clean period following an incident:

| Window | Coverage |
|---|---|
| `[1m]` | 100.00% |
| `[5m]` | 99.73% |
| `[15m]` | 86.78% |

The Grafana panel uses `[5m]`, so it takes five minutes to climb back after an
incident ends, and a resolved dip is indistinguishable from an ongoing one
unless you compare windows. Anyone watching that panel during a game day will
misread it exactly this way. Worth a sentence in the post.

---

## What to do next

1. Fix bug 1 (delta over common series only) and bug 2 (settle after remesh).
2. Resolve bug 3 — decide what "membership converged" means on BEL and assert on
   that series specifically.
3. Investigate the 3 → 4 active-pool change, then re-size FM3's fault from the
   band actually in force.
4. Re-run fm2-hard, fm3, fm4. fm1 and fm2-graceful do not need re-running.
