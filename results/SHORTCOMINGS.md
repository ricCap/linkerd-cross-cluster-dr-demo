# Shortcomings of this exercise

An honest audit of what these experiments do **not** establish. Written for the
post, because a playbook that argues "measure, do not assume" and then presents
unqualified single observations would be arguing against itself.

Ordered by how much each would undermine a published claim.

---

## 1. Almost every number is n=1

FM2, FM4 and FM1 were each run **once**. FM3 was run three times, and even there
the spread is visible: the load band was crossed at 11s, 16s and 22s across
runs — roughly a 2x range on the headline reaction time.

So "6s graceful vs 82s partitioned" is one observation of each. The 13x gap is
almost certainly real, because the mechanism (refused connections vs blackholed
packets) is deterministic. The *magnitudes* are not trustworthy to two
significant figures and should not be quoted as if they were.

**Fix:** run each mode 5+ times and report median plus range. Cheap — the
runners are already idempotent and scriptable.

**Until then:** phrase results as orders of magnitude ("seconds vs minutes"),
not as precise timings.

---

## 2. The non-federated controls are a rigged fight

`api-east` and `analytics-east-gw` are pinned to east by construction, and FM2
kills east. Of course they drop to 0%.

That demonstrates *the cost of pinning a client to one cluster*. It does **not**
demonstrate that federation beats a well-designed non-federated setup. A fairer
control would be flat mirrors to two clusters with a client-side fallback, or an
HTTPRoute with a backup backend — both of which would survive the same fault.

The honest claim is: **federation removes the need to design that failover
yourself, and removes the chance of getting it wrong.** Not: "the alternatives
do not work."

See also §12: the three modes are now measured under all four faults, but they
are not measured on equal terms.

---

## 3. One load profile, one protocol, one traffic shape

Everything ran at a constant 30 rps of short HTTP requests against `podinfo`.
Nothing here covers:

- **gRPC or long-lived streams**, which behave very differently on failover —
  an established stream to a dying cluster does not get re-balanced the way a
  new request does.
- **Bursty or ramping load.** HAZL's load band is `latency x throughput`, so
  every FM3 result is specific to 30 rps. At 300 rps the same latency injection
  crosses the band far sooner, and at 3 rps it may never cross it at all.
- **Tuned client behaviour.** No retry budgets, no timeouts chosen to match the
  measured failover windows. Real clients would mask or amplify these results.

FM3's numbers in particular are load-specific *by construction* and should be
labelled as such.

---

## 4. Some findings were k3d artifacts wearing a DR costume  *(largely fixed)*

**Fixed.** The IP-drift-on-reattach failure — nodes coming back on different
addresses, wedging k3s and orphaning every Link — was **Docker network
behaviour**, not cloud behaviour. Addresses are now recorded before a partition
and restored on reattach, so it no longer happens: verified with a hard
partition and restore where `east` returned on its original addresses, needed no
cluster cycle, kept its Links, and brought every pod back meshed.

The residual is honest: reattaching does not revive the kubelet, so agent nodes
come back NotReady and need a container restart. That is plausible cloud
behaviour and the restore path now does it explicitly.

Historical note on the original problem, which is why this section exists: On EKS/GKE, node addresses do not shuffle when a partition
heals, and managed control planes do not wedge this way.

The underlying lesson survives: **Links pin the target API address at creation,
so if that address changes, mirroring is dead until you re-link.** That is worth
saying. But the *mechanism* demonstrated here would not reproduce on a managed
cluster, and presenting the reproduction as "what a region event looks like"
would be misleading.

### Correction (2026-08-17): the unmeshed-pod claim below was wrong

This section previously said fixing the address drift "also removed most of the
unmeshed-pod incidents", and that the exercise was triggering them "far more
often than a real cluster would". **The 2026-08-17 BEL run falsifies that.**

Unmeshed pods reproduced on **two out of two** hard-partition restores, with
addresses pinned, no address drift, and no cluster cycle. Evidence from `east`
after the first restore — four pods with no init containers at all, while their
siblings in the same ReplicaSet have both:

| Pod | Created | Init containers |
|---|---|---|
| `frontend-…-5pvm7` | 15:10:**40** | `<none>` |
| `frontend-…-wfv2c` | 15:10:**53** | `linkerd-init, linkerd-proxy` |
| `frontend-…-jljtk` | 15:10:**59** | `linkerd-init, linkerd-proxy` |

One per deployment — `frontend`, `api`, `analytics` and `loadgen`. The pods
created 13–19 seconds earlier lost the race with the proxy injector; the later
ones won it.

So the mechanism is **not** downstream of the k3d artifact, and its frequency is
not an artifact of cluster cycling either: an ordinary partition-and-restore is
enough. That strengthens the headline finding rather than qualifying it.

What survives of the original caveat is narrower and still fair: production
restores whole clusters less often than this exercise does, so the *rate* at
which you would meet this is lower — but the trigger is a routine recovery, not
a harness quirk.

Related, and also new: **one `verify/meshed.sh --fix` pass is not always
enough.** The restart it issues races the injector too. The first pass found 3
unmeshed pods and left 4; a second pass was needed. Fixing that loop belongs in
`meshed.sh` itself.

See `results/run-2026-08-17/SUMMARY.md` for the full run report.

---

## 5. The dataset is not internally consistent

Four separate inconsistencies, all introduced by iterating. Note the FM numbers
below are the *current* ones; the runs happened in a different order than the
numbering implies, which is part of the problem.

| Issue | Effect |
|---|---|
| FM4 (region) measured on OSS, everything else on BEL | one row of the results table is a different system |
| Mesh enforcement enabled between the cluster run and the control-plane run | FM2 and FM3 ran with `failurePolicy=Ignore`, FM1 with `Fail` |
| FM2's convergence timing never re-measured on BEL after the metric was fixed | no trustworthy BEL convergence figure |
| **Every FM4 number predates the region swap** | measured observing from `east`, against `region-a` = `west` + `central`; the runner now observes from `west` against `east` + `central` |

None of these invalidate the individual results. All of them mean the table
cannot be read as one controlled experiment.

The last one is the most consequential right now: FM4's convergence time,
throughput and error figures were all taken under the old topology and need
re-measuring before they can sit in the same table as the rest.

---

## 6. FM5 is missing entirely

The trust anchor is the only failure domain with no failover target, which makes
it the most consequential of the five — and it is the one not tested. The post
currently reasons about it rather than measuring it.

---

## 7. No latency measurement anywhere

Every result is throughput, error count, or endpoint count. Not one number
describes **what the failover felt like to a client**: no p50, no p99, no tail
during the convergence window.

For FM3 this is a real gap rather than an omission — the entire premise is that
a zone got *slow*, and we never report what the client's latency did. We infer
it from HAZL's internal load average instead of measuring it directly.

---

## 8. The recovery paths were demo-grade  *(largely fixed)*

East had to be repaired by hand twice and FM4's restore hung for 17 minutes
before being killed — all downstream of the address drift in §4. With addresses
pinned and kubelets restarted explicitly, a hard partition now restores cleanly
and unattended.

Still unproven: FM4's restore has not been re-run since the fix — nor since the
region swap, which changed both the clusters it partitions and the cluster it
observes from — and the experiments have not been run back-to-back unattended,
which is the real test of "repeatable".

---

## 9. Chaos Mesh earns its keep in exactly one experiment

It is installed on all three clusters — 7 pods each, 21 total — and used only by
FM3, because it is the only fault that must be injected inside the cluster at
the network level. Cluster and region loss happen at the Docker layer (no
in-cluster tool can kill its own cluster) and FM1 is a `kubectl scale`.

Either use it for more (it can do pod-level partitions, packet loss, and
corruption, which would make FM2/FM4 more realistic than a clean cut), or drop
it and inject the FM3 latency another way. Carrying a chaos platform for one
`NetworkChaos` object is hard to justify in a repo whose selling point is that
you can run it on a laptop.

---

## 10. Only clean, symmetric partitions

Every network fault here is a total, bidirectional cut. Real network events are
partial and asymmetric: one direction works, some packets get through, latency
spikes rather than connectivity vanishing. Those are meaningfully harder to
detect and route around, and this exercise says nothing about them.

FM3's brownout is the only degradation-rather-than-failure case, and it is
applied uniformly.

---

## 11. Everything was measured on a NON-HA install

Neither install path enables high availability. The BEL values file sets only
`clusterNetworks` and the destination controller's zone-weights arg; the OSS
path calls `linkerd install` without `--ha`. So every run used single-replica
`destination`, `identity` and `proxy-injector`, with no anti-affinity and no
PodDisruptionBudgets.

This qualifies the headline finding. Linkerd's HA mode ships a stricter webhook
failure policy — the docs say the injector "is deployed with a stricter failure
policy to enforce automatic proxy injection", and that failed injection means
"the workload admission will be rejected by the Kubernetes API server, and the
deployment will fail". That is `failurePolicy: Fail`.

**So the unmeshed-pod finding would not reproduce on an HA install.** Those pods
would have been rejected at admission rather than admitted without a proxy.

The finding is still real and still worth the space it gets — the default install
is what many people run, and the gap between "installed" and "installed for
production" is exactly the kind of silent difference this exercise exists to
surface. But it must be stated as *a property of the default install*, not of
Linkerd in general.

Two knock-on effects:

- **FM1 is a harsher fault than an HA user would meet.** Scaling a single-replica
  controller to zero is not the same event as losing three replicas spread across
  nodes behind a PDB. The mechanism (discovery freezes, traffic continues) holds
  regardless; the likelihood framing does not.
- **`clusters/10-enforce-mesh.sh` is the better instrument, and should be
  described as such.** It flips `failurePolicy` alone, isolating the variable
  under test, where `--ha` changes replicas, affinity, PDBs and resources at
  once. Worth noting in the post that HA is how people realistically acquire
  that setting.

**Fix:** run the suite a second time with HA enabled and report both. The
interesting comparison is not "HA is better" but *what a control-plane outage
costs you under each* — under `Fail`, FM1 stops being a silent-degradation story
and becomes a loud availability one.

---

## 12. The three exposure modes are measured, but not on equal terms

For a long stretch of this exercise only FM2 compared all three modes. FM1
measured federated alone, FM3 measured federated alone, and FM4 gained its
gateway control by accident — the topology was rearranged to keep the
observability stack out of the blast radius, and moving the observer to `west`
happened to put a gateway mirror in front of it.

That is now fixed deliberately rather than incidentally: `central` sources a
gateway link so FM1 can see one, the FM3 brownout slows all three workloads
instead of only `frontend`, and every runner reads its mode targets from one
table in `clusters/lib.sh`. Four caveats survive the fix.

**The comparison is not like-for-like.** All three modes are driven at the same
request rate but do not have the same number of backends behind them: 9
endpoints federated, 3 flat, and **1** through the gateway — the gateway address
itself. "Federated held throughput" therefore partly reflects having more places
to put the traffic. This compounds §2 rather than repeating it: §2 is about the
non-federated modes being *pinned*, this is about them being *smaller*.

**FM3's gateway result is partly an artifact of replica count.** The finding —
that a gateway mirror gives the client one endpoint with no zone label, so
load-aware routing has nothing to act on — is asserted against the zone signal
rather than the count, which is the right thing to assert. But `linkerd-gateway`
runs a single replica here. At N replicas the client would see N endpoints and
could balance across them. They would still be zone-blind, so the mechanism
holds; the starkness of "pool of 1" does not.

**Gateway mode is one service, mirrored from one cluster.** `analytics` exists
only in `east`, and only `west` and `central` source gateway links to it. `east`
sources none, because it is the target. So every gateway number in this exercise
describes the same single path.

**FM1's mode-inversion claim is a hypothesis, not yet a result.** The destination
variant now predicts that a gateway mirror *reports* a backend failure that the
frozen destination controller hides from the other two modes, because gateway
mirrors resolve their backends in the target cluster. The mechanism is sound and
the check is written to distinguish the outcomes — but as of writing this has not
been run against a live cluster, and it is written up here as a prediction rather
than a measurement. Until it runs it belongs in neither the post nor the
findings.

---

## 13. Instrument defects found in review, and what changed  *(fixed; partly verified)*

An independent pass over the runners found problems in the **measurement**
rather than in the mesh. All are fixed in code. **Every number above was taken
with the old instrument and none has been re-measured.**

Verification status of the fixes themselves, on a live three-cluster rig:

| Fix | Status |
|---|---|
| client-side reading (`k6_client_view`) | **verified** — `task fm0` reports attempted requests matching the proxy count |
| `maxVUs` sized off the timeout | **verified** — 0 dropped iterations at rest |
| `task fm0` control run | **verified** — 100% of nominal on all three modes, 0 errors |
| convergence resolution and tolerance | **unverified** — needs a fault run |
| generator-stall detection | **unverified** — needs a fault run |
| `counter_delta` reset guard | **unverified** — needs a loadgen restart to trigger |
| `PROFILE` / `ENFORCE_MESH` wiring | **unverified** — every run so far used the default profile |

**The headline claim was inferred, not observed.** "A request with no endpoints
hangs in the balancer and never increments `response_total`" was deduced from
the *absence* of proxy metrics — which is also exactly what "the request was
never sent" looks like. `load/steady.js` had defined `dr_requests` and
`dr_errors` since the beginning and nothing ever read them. k6's REST API is now
enabled (`--address`) and `k6_client_view` in `verify/lib.sh` reads attempted
requests, client errors, dropped iterations and timeouts at every snapshot.

**The client could not sustain the configured rate.** `constant-arrival-rate`
holds a VU for a hanging request's full timeout, so offering 30 rps with
everything hanging needs 30 x 10s = 300 VUs. `maxVUs` was 120. The generator
starved for VUs during precisely the failures being measured, and every
"% of expected" was computed against a rate never actually offered. `maxVUs` is
now derived from the timeout, and the runners prefer the client's *attempted*
count over nominal `RPS x elapsed`, saying which basis they used.

**Convergence timing sat on its own noise floor.** The old loop polled every 5s
and subtracted 10, quantising results to ~5s plus CLI latency. The 82s partition
is well resolved by that; the **6s graceful stop is one or two poll cycles**,
and the instrument could not distinguish 1s from 8s. The headline "13x from the
same logical fault" therefore paired a solid number with an unresolved one. Now
polls at 1s, takes one snapshot per poll, and reports a tolerance alongside the
figure so it cannot be quoted as exact. **Until FM2 is re-run, quote the
mechanism, not the multiplier.**

**"Converged" and "the generator died" were the same observation.** Convergence
was declared when traffic to the dead cluster stopped advancing — which is also
what VU starvation looks like, and VU starvation was most likely during exactly
these faults. The loop now samples total traffic for the mode in the same
snapshot and refuses to report a time if everything stopped together.

**Counter resets flowed into results.** `distribution_delta` guarded against
negative deltas; `throughput_delta` and `error_delta` did not. A loadgen restart
mid-run — and the loadgen *is* the instrument — produced a negative delta,
a nonsense percentage, and a confident PASS/FAIL. `counter_delta` now refuses.

**`ENFORCE_MESH` did nothing.** Defined and documented in `clusters/lib.sh`,
referenced by no other file. `ENFORCE_MESH=1 task up` silently ran the defaults,
so no enforced-mode result was reproducible from the documented interface. Now
wired into `task up` via `task enforce`, and applying it restarts the app
workloads — the inbound-policy annotation is read at proxy startup, so without
that the cluster reported "enforced" while every running pod still accepted
plaintext.

**A control run is only trustworthy on a settled rig.** Observed while
validating this: a control run started ~90s after every workload was restarted
read **32% / 52% / 100%** across the three exposure modes with nothing wrong.
The federated service was worst because it has the most endpoints to
re-establish; the gateway mirror was unaffected because it resolves to a stable
node address rather than pod IPs. `task fm0` correctly refused to certify the
window, but blamed the instrument. It now checks pod ages first and says so.
Wait ~3 minutes after any restart before measuring anything.

**§1's fix now has a floor to measure against.** `task fm0` runs the full
measurement path with no fault injected — see *Before a run that matters* in the
README.

**§11 is addressable rather than merely acknowledged.** `PROFILE=production`
installs HA and enforces mesh membership — see *Profiles* in the README. §11
stands as written for every result recorded above.

---

## What this exercise does establish

Worth stating so the caveats do not swallow the results. Each of these is a
*mechanism* demonstrated to exist, which does not depend on the precision of the
timings:

- Recovered clusters can come back with workloads outside the mesh, serving
  plaintext, with authorization unenforced — caused by two documented defaults.
- Error rate can report a healthy service that is serving 2% of its traffic,
  because hung requests never complete and never increment a counter.
- A frozen discovery layer is invisible: the mesh keeps serving and stops
  learning.
- Identity loss does not break running traffic but does block the scale-up your
  failover depends on.
- HAZL reacts to degradation that produces no Kubernetes signal at all.
- Published and documented metric names did not match the running proxy on
  three separate occasions.

Those are the claims the post can make without qualification. The numbers are
illustrations of them, not the finding itself.

---

## 14. The load generators died with the clusters they were measuring  *(fixed)*

A generator ran in every cluster, on the reasoning that killing the only one
would stop an experiment rather than measure it. Sound reasoning, wrong
consequence: co-locating generators with the workloads they drive means a fault
removes **demand** at the same moment it removes **supply**.

Measured from the archived 2026-08-27 TSDB across the FM4 window — outbound rate
per generating cluster, then inbound rate at the survivor:

```
outbound  west     30  31  30  29  30  30  30  30    unchanged
          east     29  30  19  30                    series ends: generator died
          central  29  30  30                        series ends: generator died

inbound   west     68  61  31  26   8  10  38  52    it went DOWN
```

**West served less during the outage, not more.** Two thirds of the offered load
died with the clusters generating it, so the survivor was never stressed and
"the surviving region absorbs the traffic" was never tested. What the check
actually measured is west's own client-side rate holding at 30 rps — a real
result, and a much narrower one than its name:

> A client in the surviving region kept being served at its full rate while two
> thirds of the endpoints disappeared.

The same applies to FM2: east's generator died too, so west and central never
carried east's share.

**Fixed** by `LOAD_CLUSTERS` (default `west`), the one cluster no experiment
touches. Offered load now stays constant while serving capacity shrinks, so
absorption becomes a measurement instead of an assumption.

Two consequences, both deliberate:

- **FM3 no longer browns out west.** `BROWNOUT_CLUSTERS` excludes the load
  cluster, because slowing the zone the client lives in measures the client as
  much as the mesh. The fault is now a zone slice across two clusters of three.
  The claim under test is unchanged; the band arithmetic moves, so read the band
  before injecting.
- **FM1 brings up its own generator in the target cluster and removes it after.**
  A stale endpoint pool is a property of one proxy — west's view is maintained
  by west's own destination controller, so a west client cannot see central's
  freeze. FM1 is the one experiment that must measure from the cluster it
  breaks.

**Every FM2 and FM4 throughput number in `results/run-2026-08-27/SUMMARY.md`
predates this fix** and should be read as "the client's own rate held", not "the
survivors absorbed the load". The absorption claim needs a re-run.

---

## 15. The 2026-08-27 instrument defects sat unfixed until now  *(fixed in code; unverified on a rig)*

The 2026-08-27 run "spent as much effort auditing the instrument as reading it,
and that was the right ratio" — it found seven defects and wrote them up in
order of consequence. **None of the top four were then fixed.** A re-run against
that code would have reproduced them and produced another day of numbers that
could not be published.

Documenting a defect is not fixing it, and a repo whose argument is *measure,
do not assume* is the wrong place to learn that twice. Fixed now:

| # | Defect | Fix | Verified |
|---|---|---|---|
| 1 | FM4 timed convergence on `adaptive_endpoints`, which is not a membership signal | now uses `converge_by_traffic`, the behavioural measure FM2 already used; the count is printed, never checked | fixture only |
| 2 | mTLS checks read a **cumulative** counter, so every run inherited the plaintext of every run before it | new `nontls_delta` in `verify/lib.sh`, guarded by `counter_delta`; used by FM2 and FM4 | fixture |
| 3 | FM1's throughput denominator was `RPS × SETTLE`, reporting **113%** for traffic that was exactly nominal | every `snapshot` stamps its time; the denominator is real elapsed time, as FM2's already was | fixture |
| 4 | FM3's contraction check accepted `active <= baseline`, so a collapse to 1 read as healthy contraction | requires a return **to** the baseline, and reports an undershoot as a collapse with the likely cause | fixture |
| 5 | FM3's comparison checks read **end state**, so the same experiment reported PASS and FAIL for the same widening | peak active is now sampled per mode throughout the window; traffic counts stay end-state, which is correct for cumulative counters | fixture |
| 5b | FM3 asserted widening on `app-flat`, which structurally **cannot** widen | a mode with room must widen; a mode at its ceiling must redistribute — asserted separately, and which applies is read from the topology | fixture |
| 6 | `task viz:phase` existed and no runner called it, so all 854 live samples were `phase="unknown"` | `mark_phase` in `verify/lib.sh`, called at baseline / injected / restored in all four runners | end to end |

Two things were **not** done as originally planned, and the reasoning matters:

**No automated counter reset.** The 2026-08-27 workaround was to restart the
load generator so counters started from zero. With the deltas above that is
unnecessary, and it is actively harmful: a restart forces the ~3-minute settle
this document already warns about, and the restart is exactly what creates the
churned series that made `api-east` read **-5381 reqs (-73%)**. The delta is the
fix; the reset was the symptom-level workaround.

**A settle guard instead.** `verify/fm0-control.sh` already knew that an
unsettled rig reads 32% / 52% / 100% across the three modes with nothing wrong —
but it used that only to *explain* a bad number after the fact. A fault runner
cannot afford that: by the time the number looks odd, the fault is injected and
the window is gone. `require_settled` is now a precondition in all four runners,
overridable with `SETTLE_GUARD=0`, which prints a warning saying not to publish
from that run.

### Verification status, updated after the 2026-09-07 rig

Several of the above have now run against a live three-cluster rig, and the
distinction matters — §13 records a previous batch as "fixed in code" that had
never been exercised.

| Fix | Status |
|---|---|
| FM1 denominator (elapsed, not `RPS × SETTLE`) | **live** — FM1c reported a 119s window and percentages consistent with it |
| FM1a/FM1c flat-mirror throughput assertion | **live** — caught the flat mirror at 13% on zero errors |
| `mark_phase` wiring | **live** |
| `require_settled` | **live** — and found to be insufficient on its own, see below |
| FM4 → `converge_by_traffic` | **fixture only** — FM4 has not been re-run |
| `nontls_delta` | **fixture only** — no fault has produced plaintext since |
| FM3 peak-active and contraction checks | **fixture only** — FM3 has not been re-run |

`task fm0` passed 6/6 twice on 2026-09-07, at 99% and then 100% of nominal
across all three modes with zero errors and zero dropped iterations. That
establishes the instrument reads clean at rest. It does not establish that the
un-exercised checks above behave correctly under a fault.

### Three defects the live rig then found, which fixtures could not have

Worth recording as an argument for running things rather than reasoning about
them.

1. **FM1's freeze check read the balancer, and broke its own window.** It used
   `adaptive_endpoints` and exited the watch loop the moment that moved — so an
   unreliable reading at t+0 collapsed a 90s window to 17s, and every other
   check in the run was then computed over seventeen seconds. Now reads the
   destination controller and holds the window regardless.
2. **FM1c's fault was partial**, leaving `linkerd-local-service-mirror` running.
3. **The FM1 restore silently propagated a broken rig.** Its glob missed that
   same component, so a run scaled four things down, restored three, and
   printed "control plane restored"; the next run then recorded the resulting 0
   as the value to restore. Left alone that is permanent, with every run
   reporting success.

None of these were visible without injecting a real fault and then checking the
rig afterwards rather than trusting the runner's own summary.
