# Findings

Observed results from real runs in this environment. Numbers here are measured,
not estimated. Where something has not been re-verified after a change, it says
so.

Environment: 3 k3d clusters (west/east/central), flat network, Linkerd
`edge-26.8.1` OSS, proxy `linkerd2_proxy 2.364.0`, 30 rps per exposure mode per
cluster.

---

# FM3's premise stopped holding, and the experiment could not tell

Found by re-running FM3 before publishing its numbers, on a rig that had been
through a full day of experiments.

**The fault landed on nothing, and the run said HAZL did not react.** Load
peaked at 0.111 against a band high of 4.00, the pool never widened, and no
remote-zone traffic appeared. A clean, confident negative result.

The cause is placement:

```
loadgen zone: zone-b
west     app pods in zones: zone-a zone-c zone-b
east     app pods in zones: zone-c zone-a          <- no zone-b
central  app pods in zones: zone-c zone-a zone-a   <- no zone-b
```

FM3 slows the load generator's zone in every cluster **except** the load
cluster. Neither east nor central had a pod in `zone-b`, so the brownout
touched nothing anyone was using.

The arrangement FM3 depends on is **requested and not enforced**: the app
deployment carries a topology spread constraint with
`whenUnsatisfiable: ScheduleAnyway`, deliberately soft because a strict one
deadlocks when the hard-zone variant cordons a node. Across a session of
restarts the scheduler drifts off it, and nothing noticed.

> **A chaos experiment whose premise has quietly stopped holding reports a
> negative result rather than an error.** That is worse than a crash: it is a
> confident measurement of nothing.

`verify/fm3-verify.sh` now asserts the premise before injecting and refuses with
the zones it found. Writing that check surfaced one more instance of the same
shape — `z="$(kubectl get node "$n" ...)"` aborts under `set -e` when a pod has
no node yet, so the check died silently instead of explaining itself.

### Consequence for the write-up

**FM3's specific figures are not publishable.** The clearest run — load peak
6.147 against 6.00, pool 3 → 4, 11% remote — also ran with the federated pool
degraded to **7 of 9** by a preceding experiment. The *mechanism* reproduced
across several runs and is safe to publish; the numbers are not, and the post
now says so rather than quoting them.

---

# FM5 — the trust anchor, measured at last

The fifth failure mode, and the one this repo has reasoned about since the
beginning without ever running. Two arms, and the first one failed to break
anything, which turned out to be the better result.

## Linkerd fails safe on issuer drift

Re-issuing **east**'s issuer from a rogue root and restarting identity changed
nothing: east served **4227 requests** straight through the window. The control
plane refused the certificate.

```
Skipping issuer update as certs could not be read from disk: failed to verify
issuer credentials for 'identity.linkerd.cluster.local' with trust anchors:
x509: certificate signed by unknown authority
```

`linkerd-identity` validates a new issuer **against the trust anchors before
adopting it**, and on failure keeps serving with the previous one. It neither
adopts the bad certificate nor crashes.

**The DR cost is that a botched rotation is therefore silent.** One warning log
line, no metric, no failed check, and a clock running until the old issuer
expires — 90 days here. Nothing on a dashboard distinguishes "rotation applied"
from "rotation rejected and quietly ignored". That is a runbook item: after any
rotation, confirm the issuer was *adopted*, not merely applied.

## A rotation that completes in one cluster and reaches no other

The fault that does land has to rotate **both halves** — a rogue anchor and an
issuer minted from it — leaving the cluster internally consistent and externally
incompatible. That is the shape Buoyant's docs describe as uncovered:
*"multicluster trust rotation is not yet available."*

| Check | Result |
|---|---|
| traffic to the drifted cluster stops | **PASS** — 0 requests from east |
| trust failure does NOT degrade to plaintext | **PASS** — **0 non-mTLS** |
| federation holds throughput | **PASS** — **100%** of expected |
| blast radius stays inside the drifted cluster | **PASS** — west and central unaffected |

**It fails closed.** This is the exact inverse of the unmeshed-pod finding, and
the pair is the sharpest thing in the whole exercise:

| | signature | what you lose |
|---|---|---|
| unmeshed pod | traffic **succeeds**, silently in **plaintext** | security, invisibly |
| drifted anchor | traffic **stops**, still encrypted | availability, loudly |

Both are identity failures. One looks healthy and is not; the other is
impossible to miss. Knowing which you are looking at decides the runbook, and
the metric that separates them is `tls`, not the error rate.

## The fault is dormant until a pod restarts

The sharpest detail, and it was not designed for. The run restarted only
`deploy/app` in east. `app-flat` and `app-gateway` were **not** restarted — and
they kept serving at **100%**, on leaf certificates minted before the rotation.

Existing proxies hold valid leaves and the mesh does not re-validate established
peers, so a trust anchor that has already diverged shows **no symptom at all**
until something restarts and asks the drifted issuer for a certificate.

> **A broken trust anchor is invisible until the moment you need to restart
> something — which is exactly what a disaster makes you do.**

That is the latent-failure claim the write-up has been making without evidence,
and it holds without needing the idle-cluster construction: the latency is not
in *which endpoints* carry traffic, it is in *when a pod last started*.

---

# SETTLED: Topology Aware Routing cannot apply to cross-cluster traffic

The draft claims TAR keeps sending to a slow zone, and that claim was never
measured — no TAR arm ran, and hints were absent everywhere, so what this
exercise compared was HAZL against *no* zone awareness at all.

Testing it properly turned out not to need a TAR arm, because **TAR is
structurally unavailable across a cluster boundary.** Two independent reasons,
both measured on 2026-09-08 by enabling `spec.trafficDistribution: PreferClose`
on `east/app` (k3s v1.33.6) and reading the EndpointSlices.

**1. The control works.** With `PreferClose` set, east's *local* slice gets
hints immediately:

```
ip=10.22.0.77  zone=zone-b  hints=[{"name":"zone-b"}]
ip=10.22.2.68  zone=zone-a  hints=[{"name":"zone-a"}]
```

So the mechanism is available on this rig and configured correctly. Anything
absent below is absent for a structural reason, not a setup mistake.

**2. Federated and flat-mirror services have no EndpointSlices at all.**

```
app-federated        service=1  endpointslices=0
app-flat-east        service=1  endpointslices=0
app-gateway-east-gw  service=1  endpointslices=1
```

Both are **selector-less** ClusterIP Services carrying
`multicluster.linkerd.io/remote-discovery: east`. Kubernetes creates no slices
for a selector-less Service, and the destination controller resolves them
across the Link at request time — it reported **9** and **3** endpoints while
zero slices existed. This is the same mechanism FM1c found: the mirror
controllers own the Service objects, not a cached copy of their endpoints.

**3. The one mirrored slice that does exist carries no zone.** The gateway
mirror's endpoints are east's *node* addresses:

```
ip=172.28.0.7  zone=NONE  hints=NONE
ip=172.28.0.8  zone=NONE  hints=NONE
```

A node address carries no zone, so even a hint-computing controller has nothing
to compute from.

### What this means

Topology Aware Routing is a property of **EndpointSlice hints**. Cross-cluster
traffic in Linkerd either does not traverse EndpointSlices at all (federated,
remote-discovery) or traverses ones whose endpoints are zone-less node addresses
(gateway). **So TAR cannot route cross-cluster traffic by zone, and no
configuration changes that.** It is not that TAR routes badly across clusters;
it is not in the path.

That also explains what HAZL is for, better than the argument the draft
currently makes: it operates at the balancer on *observed load* rather than on
Kubernetes topology metadata, which is the only place zone-awareness can live
once traffic leaves the cluster that owns the EndpointSlice.

**Replaces the unsupported claim entirely, and needs no OSS arm.** The
three-arm comparison the critique asked for is moot for the multicluster case:
there is no TAR arm to compare, because TAR does not reach here.

`verify/preflight-claims.sh` performs this check.

---

# Arm B (`PROFILE=production`) — first run ever, and it corrects a claim we made three times

HA verified in force before measuring: `linkerd-destination`, `linkerd-identity`
and `linkerd-proxy-injector` all **3/3** in every cluster,
`failurePolicy=Fail`, `dr-demo` annotated `all-authenticated`. 125 pods, no
evictions. `fm0` passed 6/6 at 99%.

## `failurePolicy=Fail` does NOT change how FM1b fails

This repo states, in `SHORTCOMINGS.md` §11 and in both run summaries, that
under `PROFILE=production` the pods FM1b cannot start *"would be rejected at
admission instead of stalling in init"*.

**Measured: they still stall in init.** Same `Init:1/2`, same three pods, same
`readyReplicas` stuck at 3 of 6 for the full 120s — identical to the default
arm.

The claim confused two different components:

| what is down | admission | outcome |
|---|---|---|
| **proxy-injector** | webhook unavailable → `failurePolicy` decides | `Ignore` admits **unmeshed**; `Fail` **rejects** |
| **identity** (FM1b) | webhook is **healthy**, proxy injected fine | pod admitted **with** a proxy that cannot get a cert → `Init:1/2` |

FM1b scales `linkerd-identity` to zero. The injector stayed **3/3**
throughout, so admission succeeded and the sidecar *was* injected — the stalled
pods are `Init:1/2`, meaning `linkerd-init` completed and `linkerd-proxy` did
not. `failurePolicy` governs what happens when the **webhook** is unreachable.
It has nothing to say about a proxy that was injected correctly and then could
not reach identity.

**So the "silent security failure vs loud availability failure" trade is real
but narrower than written.** It applies to the *injector* being unavailable —
which is the unmeshed-pod finding — and not to identity loss. Under both
profiles, losing identity blocks your failover scale-up in exactly the same
way, silently, with pods that never become ready and never alert.

That is a better result than the one we predicted: the hardening knob does not
help with the failure mode that most directly breaks a failover.

---

# WHICH NUMBERS ARE VALID  (read before quoting anything below)

Two instrument changes on 2026-09-08 invalidate throughput and error figures
taken before them. The *mechanisms* recorded throughout this document all still
hold — they are directional and were never sensitive to the arithmetic. The
**magnitudes** are not, and the boundary is exact.

**The cut is commit `c7d2b57`, "Delta per series".** Before it, a delta over a
fault that removed endpoints discarded whatever those endpoints had served,
biasing every figure **downward**. That overstates a control's collapse and can
manufacture a failure for the federated service — it did exactly that, failing
FM2a at 76% on a run that was actually 100%.

| Source | Throughput / errors | Why |
|---|---|---|
| Everything before 2026-09-08 | **do not quote** | old arithmetic, and mostly a different instrument besides |
| FM1a, FM1b, FM1c (2026-09-08) | **do not quote** | ran before `c7d2b57`; qualitative results stand |
| FM3 (2026-09-08) | **valid** | uses `hazl_load`, `active_endpoints`, `locality_counts` — none touched by the fix |
| FM2a (2026-09-08) and later | **valid** | first run on the corrected arithmetic |

What survives from the pre-fix FM1 runs is everything that is not a percentage:
the proxy view held at 9 of 9 for 90s with three backends gone; the flat mirror
collapsed while logging ~1 error; the gateway mirror failed loudly with
thousands. Direction, not magnitude.

## Validated on 2026-09-08 (Arm A, `PROFILE=default`, BEL `enterprise-2.20.1`)

| | result |
|---|---|
| `fm0` control | 6/6, 100% of nominal on all three modes, 0 errors, 0 dropped |
| FM1a destination down | 4/4 — proxy view **9 → 9 across 90s** with 3 backends gone |
| FM1b identity down | 3/3 — headroom **22h17m**, scale-up 3→6 **blocked**, pods stuck `Init:1/2` |
| FM1c service-mirror down | 4/4 — destination view 9 → 6 after 5s; membership does **not** freeze |
| FM3 zone brownout | 3/3 core + 3/3 modes — peak **6.147 vs 6.00** after 12s, active **3 → 4**, 340 remote-zone reqs (11%) |
| FM2a cluster loss, graceful | 6/6 — convergence **2s (±2s)**, **0 errors**, **100%** throughput, flat 1%, gateway 1%, **0 non-mTLS** |

| FM2b cluster loss, hard partition | 6/6 — convergence **1s (±2s)**, **0 errors of 2864**, **102%** throughput, flat 1%, gateway 1%, **0 non-mTLS** |
| FM4 region loss | **6/6** on the re-run — **0 errors of 3876**, **100%** absorbed, **0 non-mTLS**, **0** reqs served by the dead region, dashboard **13/13**. Failover timing is not quotable: see the retraction below. |

### The 13x graceful-vs-partition gap does not reproduce on BEL

Measured here on the corrected instrument: **graceful 2s, partition 1s.** Both
at the measurement floor, and the partition is if anything the *faster* of the
two.

The recorded OSS progression is **6s graceful vs 82s partition**, and the
write-up's sharpest line — *"a 13x difference in detection time from the same
logical fault"* — hangs on it. On BEL that difference is gone, which is
consistent with what the 2026-08-27 run saw (1s / 0s) and which this run
confirms on an instrument that has since been rebuilt twice.

**Do not publish the 13x claim.** The mechanism it describes is real — a
graceful stop refuses connections while a partition blackholes packets, so
nothing can be concluded until timeouts expire — but the magnitude belongs to
discovery-driven failover, and HAZL does not wait for discovery. Quote the
mechanism, and say plainly that on a load-aware balancer the gap closes.

### RETRACTED: "losing a region takes far longer than losing a cluster"

Recorded here from a single FM4 run reporting 34s against 1–2s for a cluster.
**The very next run of the same experiment reported 1s.** The claim does not
survive, and the reason it does not is the more valuable finding.

| run | traffic to region-a during the failure | failover |
|---|---|---|
| 1 | east 104, central 54 | **34s** |
| 2 | east 0, central 0 | **1s** |

`converge_by_traffic` times how long traffic to the dead clusters takes to
stop. HAZL deliberately concentrates traffic on a zone-local subset, so whether
the partitioned endpoints were carrying any traffic at the instant the fault
landed decides the answer. When they were, it took 34s. When they were not,
there was nothing to converge and it registered at the measurement floor.

The 2026-08-27 run predicted exactly this and it was not acted on: *"with HAZL
holding 3 active endpoints, the volume going to east at rest is small, so
'traffic stopped' can register almost immediately."*

**So no convergence number in this document is a stable property of the fault
on BEL** — not FM2's 1s and 2s, and not either FM4 figure. They are properties
of the fault *and* of which endpoints HAZL happened to be using. Two runs of
one experiment spanning 34x is the evidence, and it is a far better argument
than any single timing would have been.

What can be said, and is worth saying:

> On a load-aware balancer, failover cost depends on whether the balancer was
> using the thing you lost. Lose endpoints it had already routed around and
> there is nothing to fail over. **That makes "how long is failover?" the wrong
> question, and "was the lost capacity in the active set?" the right one.**

Report convergence as a distribution over repeated runs with the baseline
active set recorded alongside, or do not report it. This is also why the
endpoint-count instruments were abandoned earlier: every membership signal here
is entangled with HAZL's own routing decisions.

### FM4's mTLS failure was contamination from the previous experiment

FM4 reported **2 non-mTLS**. The delta is correct; the baseline was not. Its
`baseline.metrics` already carried **469** plaintext requests to an east pod:

```
target_ip=10.22.1.75  tls=no_identity  no_tls_reason=not_provided_by_service_discovery  469
```

That pod came back unmeshed from **FM2b's recovery** — the exercise's own
headline finding, arriving as contamination in the next experiment rather than
as a result. Everything was meshed again afterwards, because FM4's restore
cleaned it, which is why it left no trace anywhere except that counter.

`require_baseline_view` counts endpoints and cannot see that one of them has no
proxy. Since an unmeshed recovery is the *expected* outcome of the preceding
experiment on this profile, that gap guarantees contamination in a sweep.
`require_meshed` now gates every runner on it, checking `.spec.initContainers`
as well as `.spec.containers` — the proxy is a native sidecar init container
from Kubernetes 1.29, and checking only `containers` once produced 52 false
positives.

**FM4's mTLS number needs a re-run behind that gate before it means anything.**

**The three-mode contrast reproduced under every fault**, and it is the finding
that does not depend on any of the arithmetic above: one fault, three outcomes,
and they are not on a single spectrum. Federated keeps serving on a stale view.
The flat mirror collapses **silently** — near-zero throughput with a clean error
rate. The gateway mirror fails **loudly**. Under FM1 the gateway is the only one
that surfaces the fault; under FM2 it is the worst performer. Same property,
opposite sign, depending on which way the fault points.

---

---

## Corrections from the 2026-08-27 BEL run

Full report: [`results/run-2026-08-27/SUMMARY.md`](run-2026-08-27/SUMMARY.md).
Seven experiments on `enterprise-2.20.1`, `PROFILE=default`. Three claims below
are corrected by it; read those sections with this in mind.

**The mTLS failures recorded for FM2-hard (2634) and FM4 (363) were measured
with a contaminated instrument.** `verify/fm2-verify.sh` asserts mTLS continuity
on the **cumulative** counter from the `during` snapshot, and proxy counters
never reset — so each run inherited the plaintext of every run before it. Before
FM2-hard even started on 2026-08-27, west was already carrying 1145 non-mTLS on
`frontend-federated` and 2418 on `api-east` from FM2a's recovery. With counters
reset first, FM2-hard's mTLS check **passed with 0 non-mTLS** while the recovery
snapshot still showed the plaintext. The conclusion — *mTLS breaks during
recovery, not failover* — survives and is now properly supported. The numbers
attached to it do not.

**The address-pinning fix is not "verified end to end", and drifts on the
gentler fault.** This document records east coming back on `.7/.8/.9` unchanged
with no cluster cycle needed. On 2026-08-27 the **graceful** stop drifted
`172.28.0.7 → .9` and required a cycle, while the **hard partition** preserved
addresses perfectly. Better characterised as "handles `docker network
disconnect`" than "handles node restarts".

**`adaptive_endpoints` is not a membership signal on BEL — treat the open
question as settled.** The 2026-08-17 note suspected the check "may be measuring
availability rather than membership". Three independent demonstrations in one
day: it dipped **9 → 5** during a purely latency-shaped fault (FM3, where
membership cannot change); it never reached 3 in FM4 while 100% throughput, zero
errors and zero requests to the dead region all said failover was complete; and
an interrupted run left west reporting **13** against 9 real pods while east and
central both reported 9. FM2 and FM4 both time convergence on it. The
behavioural measure — traffic to the target stopping — tracked reality every
time.

**Still open, and now with a second data point:** the active pool baselines at
**4**, not 3, and stayed there through six minutes of waiting with exactly three
`Running` pods per cluster. This reproduces the 2026-08-17 observation and
remains unexplained. It sets the HAZL band, so it decides whether FM3 produces a
result at all.

**Not corrected but worth flagging:** convergence timing on BEL did not
distinguish the two FM2 variants (1s graceful, 0s partition) against this
document's OSS 6s/82s. Do not mix the numbers. Re-running both variants on OSS
in the same rig would settle whether HAZL genuinely steps off a partitioned
cluster without waiting for timeouts, or whether `converge_by_traffic` simply
registers fast when HAZL is using few endpoints.

---

## FM2 — cluster failure (graceful)

`docker stop` on all three of east's nodes, observed from west.

| Measure | Result |
|---|---|
| Federated membership convergence (9 → 6 endpoints) | **6 seconds** |
| Federated errors during 90s failure window | **0** |
| Federated throughput | **2895 reqs / ~2700 expected** — fully maintained |
| Flat mirror (`api-east`) throughput | 55 reqs — **2% of expected** |
| Gateway mirror (`analytics-east-gw`) throughput | 205 reqs — **7.6% of expected** |
| Non-mTLS requests at any point | **0** |

### The headline

Federation absorbed a full cluster loss in 6 seconds with zero errors and no
loss of throughput, with no client change and no configuration change. The two
non-federated modes, driven by the same load generator against the same
workload in the same cluster, collapsed.

### The finding that matters more: error rate lied

The flat mirror logged **2 errors** during the window. Read alone, that says the
service was fine. It served **55 requests where 2700 were expected** — it was
effectively dead.

The reason is mechanical. When a mirrored service loses every endpoint, the
proxy has nowhere to send the request, so it sits in the balancer queue until
the client gives up. A request that never receives a response never increments
`response_total`. **The error counter cannot see a request that never
completed.**

This has a direct operational consequence: an SLO alert built on error rate
would not have fired for the flat mirror. One built on throughput would have
fired immediately. The gateway mirror, by contrast, produced explicit errors
(153) because the gateway itself answers — so the *same underlying failure* is
loud or silent depending purely on which exposure mode you chose.

For a client without aggressive timeouts, the flat mirror's silent hang is the
worse outcome of the two.

`verify/fm2-verify.sh` was changed after this run to assert on throughput rather
than error count.

### Recovery did not happen (superseded — see *Resolved: this was a Docker artifact* below)

After restarting east's nodes, federated membership **stayed at 6 endpoints for
the full 240s** observation window. It did not recover on its own.

Leading hypothesis: every Link pins the target's API server address at creation
time (`--api-server-address`), and a restarted container can come back on a
different address. If it does, the service-mirror controllers in the other
clusters are pointing at nothing, and membership can never recover no matter how
healthy the restored cluster is.

If that is confirmed, it is the most useful DR lesson in the whole exercise:
**recovery is not "bring the cluster back", it is "bring the cluster back and
re-establish the links."** A runbook that stops at the former leaves the mesh
permanently degraded while every dashboard shows a healthy cluster.

`chaos/fm2-cluster-loss.sh restore` now detects the drift explicitly and
re-links. Needs re-running to confirm the mechanism.

---

## FM2 — cluster failure (hard partition)

`docker network disconnect` on all three of east's nodes. Same fault "size" as
the graceful run, completely different behaviour.

| Measure | Graceful stop | Hard partition |
|---|---|---|
| Federated convergence (9 → 6) | **6 s** | **82 s** |
| Federated errors | 0 | **26** (0.5% of 5149 reqs) |
| Federated throughput | maintained | maintained |
| Flat mirror throughput | 2% of expected | 5% |
| Gateway mirror throughput | 7.6% | 6% |
| Non-mTLS requests | 0 | 0 |

### A clean shutdown is not a disaster test

**13x difference in detection time from the same logical fault.** A graceful
stop closes connections: peers are refused immediately and the system knows at
once. A partition blackholes packets — nothing is refused, so nothing can be
concluded until timeouts expire.

Every DR rehearsal that "fails" a cluster by scaling it to zero or stopping it
politely is measuring the 6-second number. The number that matters during an
actual regional event is the 82-second one. If your RTO was validated with
`kubectl scale --replicas=0`, it has not been validated.

The 26 errors follow from the same cause: during the 82s detection window the
proxy is still sending traffic to a cluster that cannot answer. Federation is
not "zero downtime" under a partition; it is "bounded, brief, and automatic".
That is still a good result — it just should not be overstated.

---

## Recovery: the cluster came back, the mesh did not

Confirmed the hypothesis from the graceful run, with a concrete mechanism.

Reconnecting containers to a Docker network reassigns addresses in reattach
order. Observed: `east-server-0` went `172.28.0.7` → `172.28.0.9`, **swapping
with an agent node**. Consequences, none of which surfaced as an alarm:

1. k3s wedged — its API certificate and internal config referenced the old
   address. The API server answered `connection reset` indefinitely.
2. Every Link pins the target API address at creation time. All of them now
   pointed at `172.28.0.7`, which had become an *agent*. The service-mirror
   controllers were talking to nothing, so federated membership could never
   recover regardless of east's health.

**The DR lesson: recovery is not "bring the cluster back", it is "bring the
cluster back AND re-establish the links."** A runbook that stops at the first
step leaves the mesh permanently degraded while every cluster-level dashboard
reports green.

`k3d cluster stop && k3d cluster start` restores deterministic addressing;
`docker start` alone does not. In a real cloud DR event addresses *will* change,
so the re-link step belongs in the runbook unconditionally.

### Resolved: this was a Docker artifact, and it is now eliminated

Everything below describes the behaviour *before* the harness was fixed. It is
kept because the diagnosis is the interesting part, but the failure no longer
occurs and **should not be presented as something a DR exercise will hit.**

The root cause was `docker network disconnect` / `connect` reassigning addresses
in reattach order. That is Docker behaviour, not cloud behaviour — on EKS or GKE
a node keeps its address across a network event — so the harness was injecting a
failure mode real users do not have, and then attributing DR lessons to it.

The fix is to record each container's address before cutting it off and reattach
with exactly that address (`save_node_ips` / `restore_node_ip` in
`clusters/lib.sh`). Verified end to end: after a hard partition and restore,
`east` came back on `172.28.0.7 / .8 / .9` unchanged, no cluster cycle was
needed, and the Links stayed valid.

> **Correction (2026-08-17).** This paragraph originally also claimed "no pods
> came back unmeshed — the injector churn that caused that was itself a
> consequence of the address drift." That is **wrong**. With addresses pinned
> and no cluster cycle, unmeshed pods still reproduced on two out of two hard
> partition restores. The address fix solved the address problem only; the
> injector race is independent of it. See the 2026-08-17 run section below.

One genuine residual: reattaching restores connectivity but does not revive the
kubelet. Agent nodes come back `NotReady` and stay there — still NotReady after
120 seconds of waiting. They need a container restart to re-register. That *is*
plausible cloud behaviour (a node that loses the API server for long enough
needs to rejoin) and the restore path now does it explicitly.

**What survives as a real lesson**, independent of the artifact: Linkerd Links
pin the target's API server address at creation time. If that address ever
changes — a rebuilt control plane, a new load balancer, a migrated endpoint —
mirroring is silently dead until you re-link. Worth a check in the runbook. We
just no longer manufacture it by accident.

### For the record: what the drift looked like

The same mechanism recurred during the region experiment and took out both
clusters at once: `west-server-0` moved `.3 → .5` and `central-server-0` moved
`.11 → .13`. Neither API server ever returned. The restore sat waiting for them
for **17 minutes** before being killed.

Two things this makes clear:

1. It is not a one-off. Address reassignment on reattach is the *normal*
   behaviour, so any runbook step of the form "reconnect the network and wait
   for the cluster to come back" is waiting for something that will not happen.
2. **Waiting longer is not a recovery strategy.** The failure is silent and
   indefinite — no crash, no error, just an API server that never answers. A
   generous timeout makes the outage longer, not likelier to resolve.

The recovery action has to be an explicit re-initialisation and re-link, not
patience. That is the whole difference between a runbook that works and one that
looks reasonable.

---

## Why the unmeshed pods happen, and the two settings that prevent it

The finding below reproduced **three times** — twice on OSS, once on BEL — which
was enough to stop treating it as bad luck and go looking for the cause. It is
not a bug. It is two Linkerd defaults working exactly as designed:

| Setting | Default | What it means during a control plane outage |
|---|---|---|
| proxy-injector `failurePolicy` | `Ignore` | pod is admitted **without a proxy**; admission never retries |
| `defaultInboundPolicy` | `all-unauthenticated` | meshed pods **accept plaintext** from the unmeshed pod |

The first creates the gap. The second guarantees nothing notices: every meshed
peer happily accepts the unmeshed pod's plaintext traffic, so there is no
connection error, no policy denial, and no alert. The workload is outside the
mesh and fully functional.

Both defaults are right for incremental adoption — you cannot onboard a mesh
into a running cluster if unmeshed workloads are rejected. They are wrong for
disaster recovery, where the whole point is that the system comes back in a
known state.

### The fix, and its cost

`clusters/10-enforce-mesh.sh on` sets `failurePolicy=Fail` and annotates the
app namespace `config.linkerd.io/default-inbound-policy=all-authenticated`.

With `failurePolicy=Fail`, a pod that would have been admitted unmeshed is
**rejected instead**, and the controller retries until the injector is back. All
three incidents in this exercise become impossible.

The cost is real and should be stated rather than buried: **pods cannot be
created at all while the proxy injector is unavailable.** You are trading a
silent security failure for a loud availability failure. That is usually the
right trade for anyone running a mesh specifically to get mTLS — but it is a
choice, it changes what a control plane outage looks like, and it interacts
directly with FM1 (where the control plane is the thing that is down).

The namespace-scoped inbound policy is deliberate too: flipping the whole
cluster to `all-authenticated` breaks kubelet probes and unmeshed system
components, which is a far larger change than the problem requires.

---

## The most under-reported failure: workloads come back unmeshed

This one was found by accident and is probably the single most valuable result
so far.

After east recovered, **all ten of its workload pods came back without a
Linkerd proxy.** Not crashed. Not unready. `Running`, `1/1`, passing health
checks, serving traffic — and entirely outside the mesh.

Cause: proxy injection is a mutating admission webhook served by the control
plane. On cluster restart, workloads race the control plane on the way up. Pods
admitted before the injector is available are admitted *without* a proxy, and
nothing retries.

What it cost, invisibly:
- Cross-cluster traffic to those pods changed from `tls="true"` to
  `tls="no_identity"`. **Real traffic, silently in plaintext.**
- Linkerd's authorization policies are enforced by the proxy, so they stopped
  being enforced. The linkerd-viz Prometheus in east served its admin endpoint
  to an unauthorized client and returned 200 where the other clusters correctly
  returned 403 — and the only reason that was noticed is that it *worked when it
  should not have*.
- No proxy means no proxy metrics, so the affected workloads partly disappeared
  from the very dashboards you would use to detect this.

The only visible signal was the container count: `2/2` → `1/1`.

`verify/meshed.sh` now gates on this explicitly, and is part of `task verify`.
Note it must check **both** `.spec.containers` and `.spec.initContainers`: from
Kubernetes 1.29 Linkerd injects the proxy as a native sidecar init container, so
on k3s v1.33 a check against `.spec.containers` alone reports every healthy pod
as unmeshed. Getting that wrong the first time produced 52 false positives.

This is the thesis of the whole post in one incident: **"the cluster recovered"
and "the mesh recovered" are different claims, and only the first one is on your
dashboard.**

---

## FM3 — zone brownout, and what HAZL does about it (BEL only)

A 400ms latency injection on the zone the load generator lives in. No pod
failed, no endpoint left its EndpointSlice, no Kubernetes condition changed.

| | Baseline | During brownout | After removal |
|---|---|---|---|
| Load average | 0.031 | peak **6.449** | 2.049 |
| Load band | [2.40 .. 6.00] | [3.20 .. 8.00] | [2.40 .. 6.00] |
| Active endpoints | 3 of 9 | **4** of 9 | 3 (after **10s**) |
| Remote-zone traffic | ~0 | **1260 reqs (46%)** | — |

Time from injection to the band being crossed: **16 seconds**.

### What HAZL is doing at rest, before any fault

Worth stating plainly because it is the cost argument: with 9 federated
endpoints available across three clusters, HAZL was using **3** — the zone-b
pod in *each* of the three clusters, every one reported `dst_zone_locality=local`.

It preserves zone affinity *across cluster boundaries*. The same workload on
open source Linkerd spread evenly across all 9 endpoints, zone-agnostic, which
on a real cloud bill is cross-zone egress on two thirds of requests.

### The load band is not the documented number

Buoyant's tuning guide gives `BUOYANT_BALANCER_LOAD_LOW=0.8` and
`BUOYANT_BALANCER_LOAD_HIGH=2.0`. The band this environment actually exposes was
**2.40 / 6.00**.

Those are per-endpoint values. The exposed band is the aggregate for the active
pool, measured at exactly `0.80 x active` and `2.00 x active` across every
service in the mesh:

| service | active | band low | band high | low/active |
|---|---|---|---|---|
| `frontend-federated` | 3 | 2.40 | 6.00 | 0.80 |
| `analytics-east-gw` | 3 | 2.40 | 6.00 | 0.80 |
| `api-east` | 1 | 0.80 | 2.00 | 0.80 |

The practical consequence: if you expect expansion when load average reaches
2.0, you will be wrong whenever the local pool holds more than one endpoint.
Sizing this experiment's load ramp off the documented 2.0 would have under-shot
the real threshold by 3x and produced a "HAZL did not react" result that was
purely an arithmetic error. **Read the band from
`outbound_http_balancer_adaptive_load_band_{low,high}`; do not assume it.**

### The band moves while you are measuring it

Because the band scales with the active pool, adding endpoints raises the
threshold: it went `[2.40 .. 6.00]` → `[3.20 .. 8.00]` the moment HAZL widened
from 3 to 4. That is self-stabilising — expansion immediately raises the bar for
further expansion, which is presumably deliberate damping.

It also means a naive "is load above the high band right now?" check can never
fire, because by the time you sample it the threshold has moved. Compare against
the band that was in force when the fault began.

### Why this is the case ordinary zone-aware routing gets wrong

Kubernetes Topology Aware Routing keys off topology, not load. A zone that is
slow but healthy is still, to TAR, the correct place to send traffic — so it
keeps sending, and the only signal is rising client latency. HAZL keys off
observed load, so degradation alone is enough. Nothing in the Kubernetes control
plane had to notice for the mesh to route around the problem.

---

## FM1 — control plane failure (BEL)

Nothing dies. Every pod keeps running, every cluster-level dashboard stays
green. The question is what the mesh can no longer *do*.

### FM1a — destination controller down

Scaled `linkerd-destination` to zero in `west`, then removed three of the nine
federated endpoints by scaling `east/frontend` to zero.

> Run under the old defaults, when FM1 targeted `west`. The runner now defaults
> to `central`, so that `west` — which hosts the observability stack — is never
> the cluster under test. The mechanism is unaffected; only the cluster name in
> this write-up is historical.

| Measure | Result |
|---|---|
| Endpoint pool as seen by west | **still 9 after 90s** (3 pods actually gone) |
| Errors while pointing at dead endpoints | **0** |

Discovery is frozen: west never learned that a third of its federated backends
had disappeared, and nothing alerted.

**But traffic did not break, and that nuance matters.** Zero errors. The proxy's
load balancer stops using endpoints that fail: connections to pods that no
longer exist are refused, and *failure accrual* takes those endpoints out of
rotation. There is no active health checking of endpoints -- nothing probes
them -- so describing it that way is wrong and a reviewer will say so. The
balancer routed around the dead endpoints without discovery's help, but it did
it reactively, by failing first. The risk is therefore narrower than
"failover cannot happen" — it is that the mesh's *view of the world* is stuck:
new endpoints will not be discovered, scale-ups will not be noticed, and
topology changes are invisible. Existing traffic rides through on the data
plane's own resilience.

That is a more useful finding than the dramatic version, and it is the one the
data supports.

### FM1b — identity down

| Measure | Result |
|---|---|
| Certificate headroom before injection | **23h50m** |
| Existing traffic over 90s with identity down | **96%** of expected |
| Scale-up 3 → 6 replicas | **blocked** — never reached 6 in 120s |

Existing proxies hold valid certificates and keep serving. New pods cannot get
one, so they never join the mesh. The three new replicas sat at **`Init:1/2`**
— from Kubernetes 1.29 the Linkerd proxy is a native sidecar *init* container,
so a pod without identity is stuck in init rather than crash-looping. It does
not fail; it simply never becomes ready.

> **Your failover plan requires scaling up, and scaling up requires identity.**

The 23h50m is the number to put in the runbook: with `linkerd-identity`
unavailable, that is how long the cluster serves existing traffic before proxies
start losing their identity — and it is measurable rather than assumed, from
`control_identity_cert_expiration_timestamp_seconds`.

Note the interaction with mesh enforcement: with `failurePolicy=Fail` the new
pods would be rejected at admission instead of stalling in init. Either way the
capacity does not arrive; the difference is whether it fails loudly.

---

## Two shell bugs that produced silent, wrong results

Both are worth repeating because they produce *plausible* output rather than
errors, and both were only caught by checking numbers that looked odd.

**`awk '... exit'` downstream of a large producer causes SIGPIPE.** Exiting awk
early closes the pipe while the linkerd CLI is still writing; the CLI dies with
SIGPIPE, `pipefail` turns the pipeline into exit 141, and `set -e` aborts the
script with no message. The certificate report printed its header and stopped,
which read as "no workloads found". Worse, it is a race against the 64KB pipe
buffer, so it failed *intermittently*.

**`[ cond ] && assign` is fatal under `set -e` when the condition is false.**
The compound returns 1, which `set -e` treats as an error. Used for threshold
colouring, it aborted the report for exactly the healthy case where all
thresholds were comfortably clear.

Neither produced an error message. Both looked like missing data.

---

## Revising the HAZL x trust-anchor thesis

The plan's centerpiece claim was: *under normal load HAZL keeps traffic in-zone
and in-cluster, so a stale trust bundle in another cluster is invisible until
stress makes HAZL expand into it.*

FM3's measurements say the cluster-level half of that is **wrong**. At rest HAZL
used 3 of 9 endpoints — the same-zone pod in *each of the three clusters*. All
three clusters carry traffic at steady state, so a broken trust anchor in any
one of them is visible immediately, not latent.

The zone-level half survives, and is a tighter claim:

> **Six of the nine endpoints receive no traffic at steady state.** A trust
> problem confined to those endpoints is invisible — and HAZL reaches for
> exactly those endpoints when the system is already under stress.

That is testable, and it is arguably a better story than the original: the
latent fault is not in some distant cluster you forgot about, it is in the
*same services you are already using*, on the replicas your load balancer is
deliberately not talking to right now. Rotations, restarts and partial rollouts
all leave state on idle replicas that nothing exercises until an incident does.

Constructing it requires making a cluster idle at rest (removing its same-zone
replica), because the trust anchor is per-cluster state and cannot be broken for
one pod. FM5 does that deliberately rather than pretending the original framing
held.

Recording this because the plan said to revise the thesis if the data disagreed,
and it did.

---

## The dashboard died with the region it was watching

Found the honest way: during the first FM4 run, Grafana went unreachable and it
looked like the environment had broken. It had not. Grafana and the federating
Prometheus were deployed into `west`, and `region-a` *at the time* was `west` +
`central` — so the observability stack was inside the failure domain the
experiment destroys. (The topology has since been changed; see the fix below.)

So the regional failover worked — membership converged 9 → 3 in 90 seconds and
`east` carried the traffic — and **none of it was visible while it happened.**

This is not a quirk of the test rig. It is the same mistake as putting your
status page in the datacentre it reports on, and it is easy to make in a
multicluster mesh, because "install the observability extension" is a per-cluster
action and one of those clusters has to be picked.

The uncomfortable part was that no cluster in the *original* topology was safe:
FM2 killed `east`, and FM4 killed `west` and `central`. **Any** in-cluster
placement was inside some experiment's blast radius.

Practical consequences for the exercise, and for a real DR runbook:

- Decide *before* the game day where the observability stack lives, and confirm
  it is outside the domain you are about to fail. If it is not, you will lose
  the recording of the event you ran the exercise to record.
- Post-hoc analysis must not depend on a live dashboard. This repo's experiment
  runners write raw metric snapshots to `results/` from the surviving observer,
  so the numbers survive even when the dashboard does not — which is why FM4's
  convergence time was still recoverable from that run.
- The survivor's own proxy metrics are the authoritative record during a
  regional event. `verify/watch.sh` reads them directly and works with no
  Prometheus and no Grafana at all.

### Fixed: `west` is now the cluster no experiment touches

The region assignment was the problem, not the placement. `region-a` is now
`east` + `central`, leaving `west` alone in `region-b`, and the experiment
targets moved with it:

| | Fault | Target |
|---|---|---|
| FM1 | control plane | `central` (was `west`) |
| FM2 | cluster | `east` |
| FM3 | zone brownout | app pods only, every cluster |
| FM4 | region | `region-a` = `east` + `central` |

Two things make this a demonstrated property rather than a lucky arrangement:

1. **`verify/fm4-verify.sh` refuses to run** if the observability stack is inside
   the target region. Five lines, and it is the check that would have caught the
   original mistake — "install the observability extension" is a per-cluster
   action, someone has to pick a cluster, and nothing warns you when the cluster
   you picked is the one the game day destroys.
2. **Dashboard availability is now measured**, not assumed. The runner probes
   Grafana's health endpoint from inside `west` throughout the failure window
   and reports it as a check row alongside convergence and throughput.

A side benefit: observing from `west` gives FM4 the **gateway-mirror control it
previously lacked**. Only `west` links to a gateway (`GATEWAY_LINKS="west:east"`
in `clusters/05-multicluster.sh`), so the old observer — `east` — had no gateway
mirror to report. FM4 now produces the same three-mode comparison FM2 does, from
a single injected fault.

### What this does not fix

`west` survives because we only ever fail `region-a`. A real regional event does
not consult your dashboard's placement, and there is still **no in-cluster
placement that is safe against an arbitrary region failure.** The exercise is now
observable; the production answer is unchanged — host it outside every cluster it
observes, whether that is a separate account, a separate region, or a hosted
platform. Keep both halves in the write-up: the rig demonstrates the lesson
working, and it does not repeal it.

---

## Measurement notes

Two things had to be corrected before the numbers meant anything. Both are worth
repeating in the post, because anyone reproducing this will hit them.

**Cumulative counters are not a distribution.** Proxy counters never reset, so
reporting the raw split during an outage still shows a large count for the dead
cluster — all of it accumulated *before* the fault. It reads as "the dead
cluster is still serving traffic", which is exactly backwards. Always delta
against a baseline snapshot (`distribution_delta` in `verify/lib.sh`).

**Two links to one cluster double-count federation.** Every Link carries a
`federatedServiceSelector`. west has two links to east (`east` and `east-gw`),
so leaving the default on both put east's pods in `frontend-federated` twice:
12 endpoints instead of 9, and a baseline of 25/50/25 masquerading as 33/33/33.
Caught only because `verify/multicluster.sh` asserts exact endpoint counts.

---

## 2026-08-17 BEL run — what it confirmed, and four measurement bugs

Full report: `results/run-2026-08-17/SUMMARY.md`. First run after the FM
renumbering and the region swap. Summarised here because three of its outcomes
change what this document says.

**Confirmed on a clean BEL environment:** FM1a (pool still 9 after 90s, 3 pods
gone, 0 errors), FM1b (headroom **23h52m**, existing traffic 113%, scale-up
blocked at 3/6), and FM2 graceful (**all six checks pass** — 0s detection, 0
errors, 100% throughput, 0 non-mTLS). FM2 graceful is the only run of the day
with no preceding remesh, so it is the trustworthy throughput baseline.

**The observability fix works.** The FM4 preflight refused-check passed, and
`observability stack survived the region loss` reported **13/13 probes** — the
dashboard stayed up through the whole regional failure. Also valid from FM4:
surviving region absorbed **97%**, errors **65/7133 (0.9%)**, dead region served
**48 reqs**, recovery to 9 endpoints in **261s**.

### Delta arithmetic breaks when endpoints churn

A close cousin of the "cumulative counters are not a distribution" trap below,
and it invalidated every throughput figure in FM2-hard and FM4.

`mode_totals` sums whatever `response_total` series a snapshot contains. After a
deployment restart the proxy holds the old pods' counters briefly and then
evicts them — so if the baseline holds series that are gone by the second
snapshot, the delta goes **negative**. Observed: `api-east -5381 reqs (-73%)`.

The counters did not go backwards; the population changed under the sum. Same
authority, same series count, different series:

```
baseline:  target_ip=10.22.2.59  dst_pod=api-6b7d84d966-ljvc4  count=5421
during:    (absent)              dst_pod=api-5645bb58d4-…
```

**Delta only over series present in both snapshots, keyed on the full label
set.** And do not take a baseline immediately after remeshing: the restart it
triggers is exactly what creates the doomed series.

### `endpoint_pool` may be asserting on the wrong series under BEL

FM4's `membership converges 9 → 3` **failed at 120s**, where the earlier OSS run
converged in 90s. Before treating that as a regression: `verify/metrics.md`
already records that `adaptive_endpoints` (BEL) means *endpoints available*
while OSS's `endpoints{ready}` means the whole pool — and `verify/lib.sh`
prefers `adaptive_endpoints` when present. The check may be measuring
availability rather than membership.

**Do not publish a BEL convergence number, or mix one into the OSS 6s / 82s /
90s progression, until this is settled.**

### FM3's fault is under-powered for the band it now faces

Twice: peak load **7.846** and **7.895** against a **8.00** threshold, never
crossed. HAZL still reacted (pool widened 4 → 5), so the mechanism holds — the
assertion is mis-calibrated.

`chaos/fm3-zone-brownout.sh` derives its 400ms default from a **6.0** threshold,
which assumed a 3-endpoint active pool. This environment baselines at **4**, so
the band is `[3.20 .. 8.00]`. Understand why the pool moved from 3 to 4 — the
region relabelling is the suspect — before raising the latency. The harness has
been bitten by the exact trap documented above: *read the band, do not assume
it.*

### mTLS failures are a recovery phenomenon, not a failover one

FM2-hard (2634 non-mTLS) and FM4 (363) both failed the mTLS check, and in both
the plaintext appears during the **restore**, not the outage — federated traffic
held through the partition with zero errors. "mTLS survives failover" stands;
the sharper supported claim is **mTLS breaks during recovery**, which follows
directly from the unmeshed-pod mechanism.

### The mTLS panel is a trailing indicator

Measured in a clean period after an incident: `[1m]` **100.00%**, `[5m]`
**99.73%**, `[15m]` **86.78%**. The Grafana panel uses `[5m]`, so a resolved dip
looks identical to an ongoing one for five minutes. Anyone reading that panel
live during a game day will misjudge it.

---

## Run status

This list was stale — most of it has since been run and written up above. Kept
as an index of what exists, at what n, and on which flavor.

| | Experiment | Runs | Flavor | Written up |
|---|---|---|---|---|
| FM1a | destination controller down | 1 | BEL | yes |
| FM1b | identity down | 1 | BEL | yes |
| FM2 | cluster failure, graceful | 1 | OSS | yes |
| FM2 | cluster failure, hard partition | 1 | OSS | yes |
| FM3 | zone brownout + HAZL band walk | 3 | BEL | yes |
| FM4 | region failure | 1 | OSS | yes |
| FM5 | trust anchor, all three arms | **0** | — | reasoned about, not measured |

Still outstanding:

- **FM5 in full.** The only failure domain with no failover target, and the one
  not tested. See `results/SHORTCOMINGS.md` §6.
- **FM4 re-measured on BEL**, so the results table is not one row of a different
  system. See SHORTCOMINGS §5.
- **FM4 restore re-run** since the address-pinning fix — SHORTCOMINGS §8 flags
  that it has not been exercised end to end since.
- **FM4 re-run under the new topology.** Every FM4 number above predates the
  region swap and was measured observing from `east`; the current runner
  observes from `west` and reports a third exposure mode.
- **Repeat runs.** Everything except FM3 is n=1. SHORTCOMINGS §1.

## BEL dependency confirmed

`outbound_http_balancer_adaptive_load_average`, the metric Buoyant's HAZL tuning
guide names for observing the load band, **does not exist in the OSS proxy** —
zero series present. FM3's HAZL verification therefore requires
`LINKERD_FLAVOR=bel`. On OSS the observable consequence is still visible via
`outbound_http_balancer_endpoints` (the pool changing size), but the load
average driving it is not exposed. See `verify/metrics.md`.

---

## Note on service names (2026-08-27)

Every measurement in this document was taken under the original workload names.
The rig now names them for the exposure mode they carry:

| was | now | client calls |
|---|---|---|
| `frontend` | `app` | `app-federated` |
| `api` | `app-flat` | `app-flat-east` / `app-flat-west` |
| `analytics` | `app-gateway` | `app-gateway-east-gw` |

The old names implied an application tier — a frontend calling a backend — and
there is no call chain: the load generator hits all three services directly and
concurrently. They were never tiers; each one exists to carry one cross-cluster
exposure mode, which is what makes a single fault produce three comparable
outcomes.

Recorded results are **not** rewritten. The metric series in `results/` literally
carry the old authorities, and renaming them in prose would misrepresent what
was measured. Read `frontend-federated` as `app-federated`, `api-east` as
`app-flat-east`, and `analytics-east-gw` as `app-gateway-east-gw`.

---

## The throughput delta was discarding the traffic the fault removed

FM2a failed `federated holds throughput` at **76% of expected**, on a run where
federation had in fact held perfectly. Two measures of the same window
disagreed inside the same report:

```
mode_totals delta   2275   (76%, FAIL)
distribution_delta  2952   (against ~2955 expected -- 100%)
```

`distribution_delta` was right. `mode_totals` sums whatever series a snapshot
contains, and the proxy **evicts series for endpoints that no longer exist** —
so east's series were in the baseline and gone from `during`, and subtracting
one sum from the other threw away traffic that had genuinely been served before
the fault. Counted directly: baseline held 4 `app-federated` series (2 in
east), `during` held 3 (1 in east).

This document has prescribed the fix since 2026-08-17 — *"delta only over
series present in both snapshots, keyed on the full label set"* — and it had
been applied to `distribution_delta` and to nothing else. `mode_totals_delta`
now does it for throughput, errors and non-mTLS, in FM1, FM2 and FM4. Series
present only in the baseline (evicted) and only in the later snapshot (new
pods) are both skipped: neither yields a meaningful delta, and including either
invents traffic.

Re-run on the same rig, same fault: **6/6, federated at 100% of expected.**

**Every throughput and error figure taken before this belongs to the old
arithmetic**, and any of them measured across a fault that removed endpoints is
biased *downward* by whatever those endpoints had served. That is the safe
direction for a control (it overstates a collapse) and the dangerous one for
the federated service, where it manufactures a failure that did not happen —
which is exactly what it did here.

One consequence worth keeping: `throughput_delta` no longer wraps the result in
`counter_delta`. The per-series pass already drops anything that went backwards,
so the wrapper could never fire. A guard that cannot fail reads like protection
and provides none.

---

## FM3 on 2026-09-08 — six attempts, five distinct defects

FM3 passed on the sixth attempt. Recording all five causes, because every one
was real and none was the mesh.

| # | peak vs 6.00 | why it failed |
|---|---|---|
| 1 | 4.697 | fault reached 2 of 3 active endpoints; sizing assumed 3 |
| 2 | 4.207 | baselined on the previous run's decaying load average |
| 3 | 5.764 | contaminated pool (AVAIL 7) inherited from FM1b |
| 4 | 5.751 | more latency stopped raising peak load |
| 5 | — | wedged 30 min in cleanup; chaos finalizers blocked deletion |
| 6 | **6.147** | **passed** |

**The fault does not reach every active endpoint.** HAZL holds one same-zone
endpoint *per cluster*, and `BROWNOUT_CLUSTERS` excludes the load cluster, so
only 2 of 3 ever get slowed and the third keeps pulling the average down. The
sizing now scales by actual reach.

**HAZL's load average needs its own settle.** `require_settled` knows about pod
age and cannot see an EWMA still unwinding from the previous run. One attempt
baselined at 3.450 instead of 0.03 and spent its whole window watching the old
fault clear. `wait_load_settled` blocks until the average is back under the
band low.

**FM1b silently degrades the rig for whatever runs next.** It scales app 3 → 6
with identity down; the new pods never leave `Init:1/2` — that is the finding —
and the restore scales replicas back to 3 while the ReplicaSet keeps a stranded
pod as one of its three. The deployment reports 3 replicas with 2 serving, the
pool reads 8 of 9, and nothing says so. FM3 then ran against `AVAIL 7`. Its
cleanup now deletes stranded pods, not just the replica count.

**A cleanup that cannot fail is worse than one that reports failure.** Chaos
Mesh finalizers blocked NetworkChaos deletion, `kubectl delete` waits by
default, and this runs from an EXIT trap with no deadline — so one run hung for
thirty minutes **with the brownout still applied**, leaving a slowed zone that
every later run would have inherited. Now bounded by `--timeout`, with a
finalizer-stripping fallback, and it reports what is still applied rather than
announcing success unconditionally.

### The load-crossing check cannot be a gate, and sizing cannot fix that

Peak across four sized runs: **500ms → 4.697, 750ms → 5.764, 900ms → 5.751.**
It asymptotes below the threshold while HAZL widens the pool every time.

More latency does not raise it. Shedding the slow endpoints lowers throughput
through them, and load is latency × throughput, so **the metric self-limits as
the mechanism under test reacts.** On top of that, this document already
recorded that expansion lifts the threshold the instant load reaches it, so
*"the crossing sits between samples by construction"*.

The check now reports the crossing instead of gating on it, and asserts the two
signals that fire reliably: the pool widened, and traffic moved off the slow
zone. The sixth run happened to catch a crossing — **peak 6.147 vs 6.00 after
12s** — which confirms it is sampling luck rather than a fault that was too
small. Treat the load average as evidence of the mechanism, never as its gate.

---

## 2026-09-08 rebuild — both FM1 arms, and a false pass caught

Rebuilt Arm A from scratch (`PROFILE=default`, BEL `enterprise-2.20.1`). `fm0`
passed 6/6 at 100% of nominal on the fresh rig.

### Both FM1 arms now pass, and reproduce the recorded numbers

| | federated | flat | gateway |
|---|---|---|---|
| FM1a (destination) | 3249 (100%), 0 err | 569 (**17%**), 1 err | 3218, **2708 err** |
| FM1a on 2026-08-27 | 3251, 1 err | 567 (**17%**), 1 err | 3219, **2741 err** |
| FM1c (mirror) | 3408 (100%), 0 err | 523 (**15%**), 0 err | 3377, **2851 err** |

The FM1a reproduction is close enough to trust the instrument changes. FM1c
produces the same shape from a *different* broken component, which is the point
of having both.

### The freeze check was passing without measuring anything

Moving FM1 onto the destination controller was right for FM1c and **wrong for
FM1a, which scales that controller to zero.** Asking it anything returned
nothing; the baseline was captured after injection so it was also nothing; and
comparing nothing to nothing passed. A green check measuring nothing, produced
by a fix intended to make the check trustworthy.

The instrument has to follow the fault. FM1a leaves the proxy's cached view as
the only view left — and it is the one under test, since the finding is that
the proxy still believes in nine endpoints when three are gone. FM1c leaves
destination running, so ask it directly.

### Correcting an over-broad claim made earlier in this document

"`adaptive_endpoints` is not a membership signal" was too strong. Measured
directly:

```
outbound_http_balancer_endpoints{endpoint_state="ready"}   3    HAZL's ACTIVE subset
outbound_http_balancer_adaptive_endpoints                  9    what the proxy knows about
```

which is what `verify/metrics.md` always said. It **is** the proxy's view of
membership. What it does unreliably is track membership *while it is changing* —
dipping 9 → 5 under a latency-only fault, never reaching 3 during FM4's
failover. FM1a is the opposite case: nothing should change, and the finding is
that nothing does. **At rest it is the correct instrument, and the original
"still 9 after 90s" result stands.** The FM4 fix is unaffected: convergence
timing is the changing case.

### A control run straight after a fault run will fail, and it is not the rig

`task fm0` failed once here with `request count for app-flat-east went
backwards (14034 -> 11036)`. The loadgen had `restartCount=0` and predated the
run, so nothing restarted.

The sum went down because the *population of series* changed under it.
`mode_totals` adds whatever `response_total` series a snapshot holds, and the
proxy evicts series for pods that no longer exist — so a baseline holding the
old pods' series, compared against a snapshot taken after eviction, subtracts
series that were never replaced. This is the "delta arithmetic breaks when
endpoints churn" trap this document already records, reappearing in the guard
rather than in a result.

`counter_delta` refused, which is correct, but its message blamed a loadgen
restart. It now names both causes and how to tell them apart. The durable fix —
delta only over series present in **both** snapshots, keyed on the full label
set, which `distribution_delta` does and `counter_delta` does not — remains
unimplemented. Until then: **let the rig settle after a fault run before
baselining the next one.** Re-run once settled, fm0 passed 6/6 at 99%.

---

## FM1c first run (2026-09-07, BEL, PROFILE=default) — and the defect it exposed

First run of the service-mirror arm. **Do not read the three failed checks as
FM1c failing**; two of them are the instrument and one is the fault being
incompletely specified.

| Check | Result |
|---|---|
| the LOCAL control plane is untouched | **PASS** — destination ready=1, mirror controllers up=0 |
| cross-cluster membership is frozen | **FAIL** — pool went 9 → 8 immediately |
| federated failure is silent | PASS — 0 errors of 502 |
| flat mirror collapses silently | **FAIL** — 96% of expected |
| gateway surfaces what discovery hid | **FAIL** — 0 errors |

### The precondition held, so this is genuinely a different fault from FM1a

`controller-east`, `controller-east-gw` and `controller-west` all stopped in
`central` while `linkerd-destination` kept serving. That is the distinction the
experiment exists to make, and it is the one thing here that is cleanly
established.

### Membership did NOT freeze, and that is the actual finding

With every service-mirror controller down, the federated pool still moved
**9 → 8**. Something other than those controllers is maintaining part of
federated membership. The obvious suspect is `linkerd-local-service-mirror`,
which runs in `linkerd-multicluster` alongside them and which this fault does
**not** touch — the controller set is discovered by the `controller-` prefix,
and that deployment does not match it.

So the fault as specified is *partial*: it breaks the per-link controllers and
leaves the local service mirror running. Whether that is the right fault depends
on a question this run cannot answer — which component owns federated membership
— and that is worth settling before the arm is re-run.

### Two of the three failures are a measurement window, not a result

The freeze check breaks its loop the moment the pool changes. It changed at
**t+0**, so the window collapsed from the intended 90s to **17s** — and all
three modes were then measured across 17 seconds, seconds after their backends
were scaled away. The flat mirror reading 96% is not "it did not collapse", it
is "it had not collapsed *yet*". The gateway reading 0 errors is the same.

**Neither number says anything about the exposure modes.** They are artifacts of
the window, and they should not be quoted.

### The defect: FM1's freeze check still reads `adaptive_endpoints`

`endpoint_pool` resolves to `adaptive_endpoints` under BEL, and this document
already records that as **not a membership signal** — it dipped 9 → 5 during a
latency-only fault, never reached 3 in FM4 while every behavioural signal said
failover was complete, and once read 13 against 9 real pods.

FM4 was moved onto the behavioural measure. **FM1 was not, and this run is what
that costs**: the freeze check is built on a signal known to misreport, and when
it misreported it also truncated the measurement window that every other check
in the run depends on.

The fix is the one FM2 and FM4 already have — decide "did this cluster learn?"
from traffic to the removed endpoints rather than from a pool count — plus
holding the full window regardless of when the pool appears to move.

**Nothing from that first run belongs in the post except the precondition result.**

### Re-run, same day, after fixing both defects

The fault now includes `linkerd-local-service-mirror` and the freeze check reads
the destination controller instead of the balancer, holding the full window
either way. All four checks pass, over a 119s window instead of 17s:

| mode | requests | errors | |
|---|---|---|---|
| federated | 3571 (100%) | **0** | silent: full throughput on a stale view |
| flat | 496 (**13%**) | **0** | the silent collapse |
| gateway | 3539 (99%) | **3011 (85%)** | the loud failure |

This reproduces the 2026-08-27 FM1a pattern closely (17% flat, 85% gateway
errors there; 13% and 85% here) from a *different* broken component, which is
the point of having both arms.

### The hypothesis was wrong, and the real mechanism is better

FM1c was written expecting the service-mirror controllers to own cross-cluster
membership, so that killing them would freeze it. **They do not.** With all four
components down — every `controller-*` plus `linkerd-local-service-mirror` —
central's destination view still tracked backends disappearing.

Checked directly on the rig: **`app-federated` has no EndpointSlices in
`central` at all.** Federated membership is resolved by the destination
controller across the Links at request time. The mirror controllers own the
Service *objects*; they do not hold a cached copy of the endpoints behind them.
So killing them stops NEW services being mirrored, and does not freeze the
endpoints of services already mirrored.

That is a sharper finding than the hypothesis it replaces, and it is now
**reported rather than asserted** in the runner — nobody has established what
*should* happen here, so a pass/fail check would encode a guess. FM1a keeps its
assertion, because a frozen destination controller genuinely does freeze the
view and that is measured.

### Residual, and it matters for any repeat run

The second run baselined with the destination view already at **6, not 9**:
east's backends had not finished coming back from the previous run when the next
one started. `require_settled` guards the pod ages in the **target** cluster
(`central`), and the backends this experiment scales away live in **east** — so
the guard cannot see the thing that is unsettled.

The three-mode numbers are unaffected (they are deltas across the window, and
the window was clean), but the membership observation is not comparable between
back-to-back runs.

**Fixed.** Two changes, because the gap had two halves:

`require_settled` now takes every cluster an experiment touches — for FM1 that
is the target, the peer whose backends are removed, and the two the
non-federated modes are pinned to. FM2 adds its target, FM4 adds the whole dead
region, FM3 adds every cluster.

That alone was not enough, and the second half is the more useful lesson. Pod
**age** cannot see this state at all: a deployment scaled to zero by a previous
run has no young pods, so an age check calls it settled. FM1 *did* already
assert a baseline of 9 — and it passed while the real view was 6, because it
asked `endpoint_pool`, which is `adaptive_endpoints` under BEL and a balancer
signal rather than a membership one. **An entry guard that consults an
unreliable instrument is worse than no guard: it certifies the thing it failed
to check.** `require_baseline_view` asks the destination controller instead.

Demonstrated rather than assumed. With east's `app` scaled to zero, the age-only
guard reports *"rig is settled"* while the new one refuses:

```
ok   rig is settled across [central] (youngest pod 9616s old, in central)
fail 'central' sees 7 endpoints for app-federated, expected 9.
```
