# BEL run — 2026-08-27

Buoyant Enterprise for Linkerd run. One experiment at a time, each written up as
it completes. Findings here are **measured**; where a number is absent it is
because that experiment has not been run yet, not because it produced nothing.

## Environment

| | |
|---|---|
| Flavor | `LINKERD_FLAVOR=bel` — enterprise-2.20.1 (chart 2.20.1) |
| Profile | `default` — single-replica control plane, `failurePolicy=Ignore` |
| Clusters | `west` (`region-b`), `east` + `central` (`region-a`) |
| Zones | 3 per cluster — server-0 `zone-a`, agent-0 `zone-b`, agent-1 `zone-c` |
| k3s | v1.33.6-k3s1 |
| Baseline pool | 9 federated endpoints (3 replicas × 3 clusters) |
| Load | 30 rps per exposure mode per cluster |
| Docker | 19.5 GB, 8 CPUs |

### Read this before quoting any FM1, FM2-recovery or FM4-recovery number

**This run is NOT highly available and NOT on Buoyant's production checklist.**
Verified on the live rig rather than assumed:

```
linkerd-destination=1/1  linkerd-identity=1/1  linkerd-proxy-injector=1/1
proxy-injector failurePolicy = Ignore
dr-demo namespace            = no all-authenticated annotation
```

The enterprise *features* are on — HAZL is live, `adaptive_endpoints` reports 9
available and 3 active — so FM3 is measuring the real thing. What is off is HA
and enforced mesh membership.

Three consequences, and they are not caveats to bury:

1. **FM1 scales a single-replica controller to zero, so it is a total control
   plane outage.** On an HA install the same action removes one replica of
   three — the event HA exists to absorb. This arm therefore measures a
   configuration Buoyant's own guidance tells you not to run in production. The
   result is still real; it is just a result *about the defaults*.
2. **The unmeshed-pod failure, if it appears, exists BECAUSE of these
   settings** — `failurePolicy=Ignore` admits a pod with no proxy and
   `all-unauthenticated` means every meshed peer accepts its plaintext, so
   nothing surfaces it. Under `production` those pods are refused at admission
   instead: a loud availability failure in place of a silent security one.
3. **Not every experiment is affected.** FM1a and FM3 are insensitive to the
   profile. FM1b and the FM2/FM4 *recovery* paths are exactly where it bites.
   FM0 involves no fault and is unaffected.

Neither arm is a superset of the other. Any claim of the form "here is what a
mesh does in a disaster" belongs to `production`; this arm is the contrast that
shows what the defaults cost you. **The `production` arm has not been run.**

Headroom at the time of the choice, for anyone reproducing: ~7–8 GiB free of
19.5 GiB allocated, CPU requests at 3%, zero evictions and zero OOMKills.

## Status

| | Experiment | Run | Written up |
|---|---|---|---|
| FM0 | control — no fault | **pass** | yes |
| FM1a | destination controller down | **2 of 3 checks pass** | yes |
| FM1b | identity down | **pass** (3/3) | yes |
| FM2a | cluster failure, graceful | **pass** (6/6) + recovery findings | yes |
| FM2b | cluster failure, hard partition | **pass** (6/6) | yes |
| FM3 | zone brownout + HAZL | **core claim pass** (3/3); 2 comparison checks fail | yes |
| FM4 | region failure | **5 of 6 checks pass** | yes |

## Instrument defect found before the first fault

`verify:dashboard` reported **`already firing before injection:
CrossZoneTrafficAppeared`** — an FM3 alert firing at rest, on a rig with
perfect zone locality. Chased down, the cause was that the rule matched *all*
outbound traffic with `dst_zone_locality="remote"`, and west's federating
Prometheus scrapes the other two clusters:

| authority | locality | rate |
|---|---|---|
| `prometheus` | remote | 0.1 rps |
| `prometheus-central` | remote | 0.1 rps |
| `prometheus-east` | remote | 0.1 rps |
| `frontend-federated` | **local** | 87 rps |
| `api-east` | **local** | 57 rps |
| `analytics-east-gw` | unknown | 57 rps |

The monitoring stack's own scrapes — 0.3 rps of genuinely cross-cluster
traffic, by construction, forever — were saturating the signal FM3 exists to
detect. **An alert that is already firing cannot report the event it is for.**

Scoped the expression to the application authorities, matching the selector the
`mesh:mode_throughput` recording rules already use. Reloaded via
`POST /-/reload` rather than the checksum-annotation restart the installer uses,
so the warm TSDB survived: pod age 19m, **0 restarts**, and the 15m baseline
stayed warm.

Two things worth keeping from how this was found:

- **`verify:dashboard` earned its keep before a single fault was injected.**
  This is precisely the class of defect it exists to catch, and it caught it.
- The `analytics-east-gw` row shows `dst_zone_locality=unknown`, not `remote`.
  A gateway mirror resolves to a node address and a node address carries no zone
  label — so gateway traffic could never have fired this alert anyway, which is
  consistent with FM3 asserting the gateway mode as a deliberate non-event.

## FM0 — control run, no fault

The null experiment: inject nothing, measure everything, check the instrument
reads clean. Without it there is no way to tell a small real effect from
measurement error.

| Measure | Result |
|---|---|
| Window | 91s, nominal ~2730 per mode |
| `frontend-federated` | 2722 reqs — **99%** of nominal, 0 errors |
| `api-east` | 2722 reqs — **99%** of nominal, 0 errors |
| `analytics-east-gw` | 2722 reqs — **99%** of nominal, 0 errors |
| Endpoint pool | **9 → 9**, stable |
| Client dropped iterations | **0** |

All six checks pass. The 1% shortfall is the sampling boundary, not loss: the
client's own counter agrees at 99%, and it dropped nothing — so the generator
offered the full configured rate and the proxies recorded essentially all of it.

**This is the number every later result is measured against.** Any mode reading
materially below 99% during a fault is the fault, not the instrument.

Zone locality at rest, measured directly, confirms the FM3 premise before FM3
runs:

| cluster | locality | rate |
|---|---|---|
| `central` | local | 30 rps |
| `east` | local | 30 rps |
| `west` | local | 28.26 rps |

Zero remote. HAZL holds traffic zone-local while the same-zone pod lives in a
*different cluster* — zone affinity preserved across cluster boundaries, with
`adaptive_endpoints` reporting all 9 available and only 3 in use.

## FM1a — destination controller down

`linkerd-destination` scaled to zero in `central`, then the backends behind
**all three** exposure modes removed in `east` while discovery was frozen.
Measured from `central`'s own load generator, because the question is what
*this* cluster can no longer do.

| Check | Result |
|---|---|
| discovery is frozen (endpoints NOT updated) | **PASS** — pool still 9 after 90s, 3 pods gone |
| federated failure is silent (no errors raised) | **FAIL** — 1 error |
| gateway mode surfaces what discovery hid | **PASS** — 2741 errors |

Throughput over the window, and this is the row that matters most:

| mode | service | requests | errors | error rate |
|---|---|---|---|---|
| federated | `frontend-federated` | **3251** | 1 | 0.03% |
| flat | `api-east` | **567** | 1 | 0.2% |
| gateway | `analytics-east-gw` | **3219** | **2741** | **85%** |

### Discovery froze exactly as predicted

`central` reported 9 endpoints for the entire 90 seconds, sampled every 5s,
while three of those nine pods no longer existed. It never learned. Nothing
alerted on the traffic path — `LinkerdDestinationDown` is what fires, and only
because it watches the component rather than the requests.

### The failed check is a real result, not a flaky assertion

The runner asserts `errors == 0` and got **1**. Rather than relax the threshold,
here is the error:

```
authority=frontend-federated  target_ip=10.22.0.8  dst_pod=frontend-5574567874-466dl
status_code=502  classification=failure  tls=true  dst_zone_locality=local   count=1
```

`10.22.x` is **east** — one request reached an east frontend pod at the instant
it was being scaled away, and got a 502. So the honest statement is sharper than
the binary check allows:

> Frozen discovery is not perfectly silent. It costs **one error in 3251
> requests (0.03%)** — the single in-flight request that hit a dying endpoint the
> stale pool still believed in. After that the balancer's own connection-level
> health checking routed around the dead endpoints without discovery's help.

That is a better finding than "zero errors", because it names the mechanism and
bounds the cost. **The assertion should probably become "< 0.1% of requests"
rather than "== 0"** — but that is a change to make deliberately, with this
reasoning attached, not to quietly paper over a red check.

### The flat mirror collapsed silently, and nothing asserted on it

`api-east` served **567 requests against 3251** for the federated service — 17%
— while logging **one** error. Its backends were gone and it had nowhere to fail
over to, so requests sat in the balancer queue until the client gave up, and a
request that never completes never increments `response_total`.

This is the "error rate lies, throughput does not" mechanism appearing in **FM1**,
where the write-up so far has only claimed it for FM2. `verify/fm1-verify.sh`
prints the throughput but asserts only on errors, so a mode that went 83% dark
passed unremarked.

### The three modes disagree, and the disagreement is the point

One fault, three outcomes, and they are not on a single spectrum:

- **federated** — full throughput, stale worldview. Fine *now*, blind to change.
- **flat** — throughput collapsed to 17%, error counter says everything is fine.
  The silent failure.
- **gateway** — full throughput, 85% of it 5xx. The loud failure.

The gateway mirror kept its throughput precisely *because* it failed loudly: its
endpoint is east's gateway address, which is still perfectly valid, and the
gateway answers — with an error. Discovery for the actual backend happens inside
east, whose control plane is healthy, so the gateway can still see what
`central` cannot.

**Pushing discovery across the cluster boundary trades silent staleness for a
loud failure.** Note this inverts FM2 and FM4, where the gateway mirror is the
worst performer. Same property, opposite sign, depending on which way the fault
points.

## FM1b — identity controller down

`linkerd-identity` scaled to zero in `central`. Certificate headroom read from
the certificates themselves before injection, then existing traffic measured,
then the scale-up every failover plan assumes.

| Check | Result |
|---|---|
| existing traffic survives identity loss | **PASS** |
| identity loss does not discriminate between modes | **PASS** |
| scale-up BLOCKED without identity | **PASS** — never reached 6 in 120s |

### The number for the runbook: 23h25m

| workload | expires in |
|---|---|
| `api` | 23h25m |
| `frontend` | 23h25m |
| `loadgen` | 23h28m |

**Minimum headroom in the cluster: 23h25m.** With `linkerd-identity`
unavailable, that is how long this cluster serves existing traffic before
proxies start losing their identity — measured from
`control_identity_cert_expiration_timestamp_seconds`, not assumed from the
nominal 24h lifetime. Put the measured number in the runbook; it is the clock
you are actually racing.

### Existing traffic is completely unaffected, and identically so

All three exposure modes served **3058 requests** over the window — the same
number to the request. Identity loss is a property of *issuance*: it says
nothing about how a request is routed once a proxy already holds a certificate.
Asserting the non-difference is the point, because a mode that fell away here
would mean the outage had reached something other than issuance. None did.
Non-mTLS requests: **0** throughout.

### The scale-up failed exactly as the mechanism predicts

`frontend` scaled 3 → 6 in `central`, watched for 120s. `readyReplicas` never
moved off 3. The pod list is the clearest evidence in this run:

```
frontend-76dff4cc8-bh574   2/2   Running
frontend-76dff4cc8-mjvpn   2/2   Running
frontend-76dff4cc8-pp2s5   2/2   Running
frontend-76dff4cc8-4wtwm   0/2   Init:1/2
frontend-76dff4cc8-628vl   0/2   Init:1/2
frontend-76dff4cc8-ttjgx   0/2   Init:1/2
```

Three old pods healthy, three new pods stuck at **`Init:1/2`** — not
`CrashLoopBackOff`, not `Error`. From Kubernetes 1.29 the Linkerd proxy is a
native sidecar *init* container, so a pod that cannot obtain an identity never
leaves init. It does not fail; it simply never becomes ready, and a pod that
never becomes ready raises no alert of its own.

> **Your failover plan requires scaling up, and scaling up requires identity.**

Note the interaction with the profile: under `PROFILE=production`
(`failurePolicy=Fail`) these pods would be *rejected at admission* instead of
stalling in init. Either way the capacity does not arrive — the difference is
whether it fails loudly. That arm has not been run.

### Instrument defect: FM1b inherits the denominator bug FM2 already fixed

The runner reported **113% of expected** for all three modes, which should be
impossible for a healthy service at a fixed rate.

`verify/fm1-verify.sh` computes `expected = RPS × SETTLE` — 30 × 90 = 2700. But
the measurement window is the *elapsed time between the two snapshots*, which
includes the injection, a 10s settle and the snapshot overhead. Working
backwards: 3058 requests ÷ 30 rps = **101.9s**, and 3058 ÷ (30 × 102) = **100%**.

The traffic was exactly nominal. The denominator was wrong.

This is the same bug `results/FINDINGS.md` records for FM2, where using `SETTLE`
alone "reported 190% of expected for a service that was merely healthy" — fixed
there by measuring elapsed time, never fixed in FM1's identity arm. It biases
*upward*, which is the dangerous direction: it would mask a real shortfall. A
mode that had actually dropped to 88% would still have printed "100%" and
passed.

**The qualitative result stands — existing traffic survives identity loss
untouched — but do not publish the 113%.** FM0 is the control that makes this
visible: it measured 99% on a healthy rig using an elapsed-time denominator, so
any figure materially above 100% here is the instrument, not the mesh.

## FM2a — cluster failure, graceful

`k3d node stop` on all three of east's nodes, observed from `west`.

| Check | Result |
|---|---|
| traffic to the dead cluster stops | **PASS** — **1s** (±1s) |
| federated absorbs failure with zero errors | **PASS** — 0 new errors |
| federated holds throughput | **PASS** — 102% of expected |
| flat mirror collapses (control) | **PASS** — 1% of expected, **0 errors** |
| gateway mirror collapses (control) | **PASS** — 6% of expected, 143 errors |
| mTLS continuity through failover | **PASS** — 0 non-mTLS |

Federated traffic during the failure, delta from baseline:

```
TOTAL 2915    west 1751    central 1134    east 30
```

East's 30 requests are all pre-convergence. The two survivors absorbed its share
with no client change and no configuration change.

### Convergence was 1 second

Faster than the 6s previously recorded for this variant. A graceful stop closes
connections, so peers are refused immediately and the system knows at once —
there is nothing to time out. **This is the number that makes the hard-partition
comparison worth running**, and it is exactly the number a DR rehearsal that
"fails" a cluster politely will report.

### The flat mirror is the cleanest silent failure yet recorded here

**1% of expected throughput. Zero errors.** Not two, not one — none at all.

A perfect error-rate SLO, on a service that was serving one request in a
hundred. The mechanism: with every endpoint gone the proxy has nowhere to send
the request, so it sits in the balancer queue until the client gives up, and a
request that never completes never increments `response_total`. The gateway
mirror, failing the same underlying way, produced 143 explicit errors — because
the gateway itself answers.

Same fault. Same workload. Same generator. One is loud, one is silent, and the
only difference is which exposure mode you chose.

---

## The most important result of the run: the cluster came back, the mesh did not

Recovery is where this experiment earned its keep. Three separate things went
wrong, none of which appeared as a failed check.

### 1. The address pin did not hold

```
reattached k3d-east-server-0 on its original address
warn: address drifted (172.28.0.7 -> 172.28.0.9); cycling the cluster
```

`results/FINDINGS.md` records the address-pinning fix as verified end to end,
with east coming back on `.7/.8/.9` unchanged and no cluster cycle needed. **It
did not hold here** — and this was the *graceful* variant, the gentler of the
two. The detection-and-cycle fallback worked (after cycling, the API address was
`172.28.0.7` again and the Links stayed valid), so the outcome was fine. The
claim that the drift is eliminated is not.

### 2. Membership did not recover inside the observation window

The pool sat at **7 of 9 for the entire 240s**, sampled every 5s, and the runner
gave up. Checked again afterwards it had reached 9 — so this is *slow*, not
*stuck*, but the runner's 240s budget is not enough for a graceful stop on BEL
and any run that trusts it will record a false "did not recover".

### 3. Workloads came back unmeshed — and the remediation reproduced the bug

The restore found **6 unmeshed pods** (3 in `dr-demo`, 1 in
`linkerd-multicluster`, 2 in `linkerd-viz`), restarted the affected deployments,
and *the restart raced the injector again*. Measured after that remediation:

```
east  analytics-85dcc59958-hvchn   1/1
east  api-757c874c86-k4kmp         1/1
east  frontend-6686d687fd-dskhj    1/1
east  loadgen-b8958857c-hz92p      1/1
```

Four pods, `Running`, `Ready`, passing health checks, serving traffic, entirely
outside the mesh. The only visible signal is the container count: `1/1` where
every healthy pod is `2/2`.

**And the traffic really was in the clear:**

| | rate |
|---|---|
| `tls="true"` | 136.36 rps |
| `tls="no_identity"` | **6.9 rps** |

Roughly **5% of application traffic in plaintext**, on a mesh installed
specifically to get mTLS, with every dashboard green and every pod Ready.

Three things make this the run's most valuable result:

1. **It reproduced on BEL, on a graceful stop.** The existing write-up ties this
   failure to hard partitions. A polite shutdown is enough.
2. **`loadgen` itself came back unmeshed.** The instrument joined the failure —
   east's generator was producing unmeshed traffic, which would contaminate the
   mTLS measurement of every subsequent experiment. This is why the environment
   must be re-verified between runs, not just between sessions.
3. **The fix reproduced the fault.** Restarting deployments to remesh them
   creates a fresh set of pods that race the injector all over again. Under
   `failurePolicy=Ignore` there is no retry — so "restart it and see" is not a
   remediation, it is another roll of the same dice. `PROFILE=production`
   (`failurePolicy=Fail`) is the actual fix, at the cost that pods cannot be
   created at all while the injector is down.

### The alerting design is vindicated here

`NonMTLSTrafficDetected` went **pending** on its own, with no prompting. Nothing
in the error rate moved — errors were **zero** — and no cluster-level signal
changed. The cross-cutting claim of this exercise is that mesh-tier failures are
caught by "something stopped" or "something is unreachable" and never by
"something returned an error", and this is the sharpest confirmation of it so
far: a security failure, with a perfect error rate, caught only by a rule that
watches the property directly.

## Instrument defect: the mTLS check reads a cumulative counter

Caught *before* FM2-hard ran, by inspecting west's proxy after FM2a's recovery:

```
frontend-federated   non-mTLS=1145
api-east             non-mTLS=2418
```

None of that traffic belonged to FM2-hard. It was accumulated during **FM2a's
recovery**, when east's pods came back unmeshed. But
`verify/fm2-verify.sh` asserts mTLS continuity on the *cumulative* value from
the `during` snapshot rather than a delta:

```bash
nontls="$(mode_totals "$(cat "${RESULTS}/during.metrics")" "$FED_SVC" | awk '{print $3}')"
```

Proxy counters never reset, so **every run inherits the plaintext of every run
before it**, and the check fails on traffic that predates the experiment. This
is the "cumulative counters are not a distribution" trap the repo documents for
traffic *distribution* — sitting unfixed in the mTLS check.

**This probably explains a published finding.** `results/FINDINGS.md` records
that *"FM2-hard (2634 non-mTLS) and FM4 (363) both failed the mTLS check"* and
attributes the plaintext to the restore. The direction of that conclusion was
right, but the evidence was contaminated: those counters would have carried
forward whatever earlier runs left behind.

Restarting west's `loadgen` to zero the counters, then letting traffic
re-establish before baselining, FM2-hard's mTLS check **passed with 0 non-mTLS**
— and the plaintext still showed up in the recovery snapshot. Same conclusion,
now actually supported.

## FM2b — cluster failure, hard partition

`docker network disconnect` on all three of east's nodes. Counters reset first.

| Check | Result |
|---|---|
| traffic to the dead cluster stops | **PASS** — **0s** (±1s) |
| federated errors bounded during detection | **PASS** — 12 of 2858 (**0.4%**) |
| federated holds throughput | **PASS** — 103% |
| flat mirror collapses (control) | **PASS** — 7%, 179 errors |
| gateway mirror collapses (control) | **PASS** — 7%, 189 errors |
| mTLS continuity through failover | **PASS** — **0 non-mTLS** |

### The headline claim of FM2 did not reproduce on BEL

The whole point of running two variants is that they should differ sharply: a
graceful stop refuses connections and converges fast, a partition blackholes
packets and cannot be detected until timeouts expire. The recorded OSS
progression is **6s graceful vs 82s partition** — a 13x gap, and the argument
that "a clean shutdown is not a disaster test."

Measured here on BEL:

| variant | convergence |
|---|---|
| graceful | **1s** (±1s) |
| hard partition | **0s** (±1s) |

**The gap is gone.** Both are at the measurement floor.

Two candidate explanations, and this run cannot separate them:

1. **Real, and a genuine BEL result.** HAZL is load-aware: it balances on
   observed latency and throughput rather than waiting for the discovery layer
   to withdraw an endpoint. A partitioned cluster stops answering, its load
   signal collapses, and the balancer steps off it without needing anything to
   time out. That would make the OSS 82s a property of discovery-driven
   failover, not of partitions as such — a strong claim, and a flattering one.
2. **A measurement artifact.** `converge_by_traffic` times when traffic to the
   target *stops*. With HAZL holding 3 active endpoints, the volume going to
   east at rest is small, so "traffic stopped" can register almost immediately
   while the endpoint is still nominally in the pool.

`results/FINDINGS.md` already warns: *"Do not publish a BEL convergence number,
or mix one into the OSS 6s / 82s / 90s progression, until this is settled."*
**That warning applies directly to these two numbers.** They are recorded here;
they should not be published as "BEL converges instantly" until arm 2 is ruled
out — most cheaply by re-running both variants on OSS in this same rig and
checking whether the 6s/82s gap reappears.

The **12 errors (0.4%)** are consistent with a real detection window: the
graceful run produced zero, this one produced a small bounded burst, which is
what "the proxy is still sending to a cluster that cannot answer" looks like.
So *something* about the partition is genuinely harder, even though convergence
timing did not show it.

### mTLS breaks during recovery, not during failover — now cleanly demonstrated

With counters reset, the federated service held **0 non-mTLS through the entire
partition**. Then, in the recovered snapshot:

```
api-east   non-mTLS=833
```

The plaintext appears on the way *back*, exactly as the unmeshed-pod mechanism
predicts. "mTLS survives failover" stands. The sharper and better-supported
claim is **mTLS breaks during recovery**.

### The address pin held here — and failed on the gentler fault

```
ok  address preserved (172.28.0.7) -- no cluster cycle needed
```

The hard partition, which is the fault the pinning fix was written for,
preserved addresses perfectly. The **graceful stop earlier in this same session
drifted `.7 → .9`** and needed a cluster cycle. That is the opposite of the
intuition that a rougher fault is more disruptive, and it means the fix is
better characterised as "handles `docker network disconnect`" than "handles node
restarts".

### Unmeshed pods reproduced again — third time today

7 pods this time (4 `dr-demo`, 2 `linkerd-multicluster`, 1 `linkerd-viz`),
after a restore that went perfectly by every other measure. Combined with FM2a
this is **3 for 3 on recovery attempts today**, on BEL, under both fault
variants. It is not a rare race; on this profile it is the expected outcome of
bringing a cluster back.

Membership itself recovered in **1s** once the pods were restarted — against
FM2a's 240s timeout. The difference is that the address did not drift here, so
no cluster cycle was needed.

## FM3 — zone brownout, and what HAZL does about it

650ms (±20ms) injected into `zone-c` across all three clusters, against all
three workloads. **Latency sized from the measured band, not the default.**

### Sizing the fault was the difference between a result and a non-result

Read before injecting:

| cluster | active | band low | band high |
|---|---|---|---|
| `west` | 4 | 3.20 | **8.00** |
| `east` | 4 | 3.20 | **8.00** |
| `central` | 3 | 2.40 | 6.00 |

The runner's 400ms default is derived from a **6.00** threshold, which assumed a
3-endpoint active pool. This rig baselines at **4**, so west faces 8.00 — and
`FINDINGS.md` records 400ms peaking at **7.846** and **7.895** against exactly
that threshold, twice, never crossing. Scaling to 650ms for margin:

**Peak load 10.044 against a high of 8.00, crossed after 5 seconds.**

The repo's own lesson — *read the band, do not assume it* — is what made this
run produce a result instead of a third near-miss.

### The self-stabilising damping, captured in full

```
t+0   load=0.186    high=8.00    active=4
t+5   load=8.221    high=10.00   active=5
t+10  load=10.044   high=12.00   active=6
t+16  load=8.874    high=12.00   active=6
t+26  load=5.679    high=8.00    active=4
t+37  load=1.972    high=4.00    active=2
t+42  load=1.172    high=2.00    active=1
```

Every widening **raises the bar for the next one** — 8.00 → 10.00 → 12.00 as the
pool goes 4 → 5 → 6 — and the ladder runs back down as load falls. This is the
clearest trace of that behaviour recorded here, and it is exactly why a naive
"is load above the high band right now?" check can never fire: by the time you
sample, the threshold has moved.

### Core claim: all three signals moved together

| Check | Result |
|---|---|
| load average crosses the band high | **PASS** — peak 10.044 vs 8.00, after **5s** |
| HAZL widens the endpoint pool | **PASS** — **4 → 6** active |
| traffic shifts to remote-zone endpoints | **PASS** — 2327 reqs, **83%** |

Throughout, every frontend pod stayed `Running` and in its EndpointSlice, and
**no Kubernetes signal fired at any point**. Topology Aware Routing keys off
topology rather than load, so it would have kept feeding the slow zone.

### The two failed checks are check-design defects, not HAZL failures

```
federated  frontend-federated   4 -> 1 of 5    458/2337/0     FAIL
flat       api-east             3 -> 3 of 3    0/2797/0       FAIL
gateway    analytics-east-gw    3 -> 3 of 3    0/0/2797       PASS
```

**Federated: the same experiment reports both PASS and FAIL for the same
behaviour.** The core check samples *throughout* and correctly caught 4 → 6. The
comparison check reads the **end state**, by which time the brownout was over,
load had collapsed to 0.036 and HAZL had contracted to 1. The sampling check is
right; the end-state check is measuring the recovery and calling it a failure.

**Flat: the check is structurally impossible for this mode.** `api-east` has
exactly 3 endpoints, one per zone, all in east. It cannot widen past 3 — there
is nowhere to widen *to*. Yet it moved **100% of its traffic off the slow zone**
(2797 remote, 0 local). It did precisely what the check is named for, by
redistributing rather than expanding, and was marked FAIL for not growing a pool
it cannot grow.

**Gateway: correct, and correctly asserted as a non-event.** 2797 requests, none
carrying a locality label at all. A gateway mirror gives the client one endpoint
— a node address — and strips the zone metadata on the way. Load-aware routing
needs endpoints to choose between. Read this as the cost of the hop, not a HAZL
limitation.

### Two further defects worth fixing

**The contraction check cannot detect collapse.** The runner printed:

```
t+0 s  active=1  (want back to 4)
ok  pool contracted back to 4 in 0s
```

It accepts `active <= baseline` as success, so it passes on a pool that has
fallen *below* where it started. "Healthy contraction" and "collapsed to a
single endpoint" are indistinguishable to it.

**Available endpoints moved under load.** Mid-run the federated pool reported
**5 available** where it had been 9, and the trailing readings show `1 of 5`.
`adaptive_endpoints` is supposed to mean *membership* — endpoints available —
not a load-dependent quantity. It returned to 9 across all three clusters after
the brownout cleared, with every pod `2/2 Ready` and no chaos objects left
behind, so nothing is broken. But a membership signal that dips during a purely
latency-shaped fault is either mis-named or mis-understood, and FM2/FM4 time
their convergence on it.

### The unexplained baseline persists

`active` sat at **4**, not the documented 3, and stayed there through six
minutes of waiting with exactly 3 `Running` pods per cluster. `central` briefly
reported **10** available against a real population of 9. This reproduces the
2026-08-17 note — *"understand why the pool moved from 3 to 4 before raising the
latency"* — and it is still unexplained. It is not cosmetic: it sets the band,
and the band decides whether the experiment produces a result at all.

## FM4 — region failure

`region-a` — **both** `east` and `central` — partitioned simultaneously,
observed from `west`, the sole survivor. Counters reset before the run so the
mTLS numbers mean something.

| Check | Result |
|---|---|
| membership converges 9 → 3 | **FAIL** — not within 120s |
| surviving region absorbs the traffic | **PASS — 100% of expected** |
| federated errors bounded | **PASS — 0 of 7399 (0.0%)** |
| mTLS continuity through regional failover | **PASS — 0 non-mTLS** |
| no traffic served by the dead region | **PASS — 0 reqs** |
| observability stack survived the region loss | **PASS — 13/13 probes** |

```
frontend-federated   7399 reqs  (100%)   federated
api-east              216 reqs  (2%)     flat mirror
analytics-east-gw     232 reqs  (3%)     gateway mirror
```

### Two of three clusters died at once and the federated service did not notice

**Zero errors across 7399 requests. 100% of expected throughput. Zero requests
served by the dead region. Zero plaintext.** No client change, no configuration
change. The two non-federated controls, driven by the same generator against the
same workload, collapsed to 2% and 3%.

This is the strongest single result of the run, and it is stronger than FM2's:
losing a whole region is not N independent cluster failures, and federation
absorbed it without a detectable dip.

### The dashboard stayed up, and that was earned rather than lucky

**13/13 probes succeeded** against Grafana from inside `west` throughout the
regional failure. Two deliberate decisions made that true:

1. `west` is alone in `region-b`, so the observability stack sits outside the
   failure domain, and `verify/fm4-verify.sh` refuses to run if it does not.
2. Grafana is reached through a NodePort and a relay container rather than
   `kubectl port-forward`, so the probe no longer depends on west's API server
   (see the exposure note earlier in this document). With the old forward, a
   stream timeout would have been indistinguishable from "the observability
   stack died with the region."

### The failed check is the instrument, and today produced three proofs of it

Traffic behaviour was flawless: 100% throughput, zero errors, zero requests to
the dead region. Failover unambiguously worked. What failed is the *membership
signal* reading 3.

`verify/lib.sh` prefers `adaptive_endpoints` under BEL, and that metric
misbehaved **three separate times today**:

| | observation |
|---|---|
| FM3 | dipped **9 → 5** during a purely latency-shaped fault, where membership cannot change |
| FM4 | never reached 3 while every behavioural signal said failover was complete |
| interrupted run | west reported **13** against 9 real pods, while east and central both reported 9 |

`FINDINGS.md` already suspected this — *"the check may be measuring availability
rather than membership"* — and warned against publishing a BEL convergence
number. **Treat that as settled: `adaptive_endpoints` is not a membership
signal, and both FM2 and FM4 currently time convergence on it.** The
behavioural measure — traffic to the dead region stopping — is the one that
tracked reality in every run today.

### Recovery: 22 unmeshed pods, and 11971 requests in plaintext

The worst recovery of the day by a wide margin.

```
7 unmeshed in dr-demo, 3 in linkerd-multicluster, 2 in linkerd-viz
  -> remesh restart ->
5 more in dr-demo, 5 more in linkerd-multicluster
22 unmeshed pods total
```

And with counters reset before the run, so this is FM4's own traffic:

| service | non-mTLS during recovery |
|---|---|
| `frontend-federated` | **11971** |
| `api-east` | 2389 |

**Zero plaintext through the entire regional outage; 11971 plaintext requests on
the way back.** That is the sharpest possible statement of the pattern, on clean
counters:

> mTLS survives failover. mTLS breaks during recovery.

Two details make it worse than the raw number suggests. **`linkerd-multicluster`
pods came back unmeshed** — the service-mirror controllers, the components that
maintain federated membership, were themselves outside the mesh. And **the
remesh restart produced 10 more unmeshed pods**, reproducing the fault while
fixing it, for the second time today.

Membership itself recovered to 9 endpoints in **0s** once addresses held, which
they did — the pin worked on this partition, as it did on FM2-hard.

## What this run establishes

Seven experiments, all on BEL `enterprise-2.20.1`, `PROFILE=default`.

**Federation absorbed every fault it was designed for, and the margin was
larger than expected.**

| fault | federated | flat mirror | gateway mirror |
|---|---|---|---|
| control plane frozen (FM1a) | 3251 reqs, 1 error | **567 reqs (17%)**, 1 error | 3219 reqs, **2741 errors** |
| cluster lost, graceful (FM2a) | 102%, **0 errors** | **1%**, 0 errors | 6%, 143 errors |
| cluster lost, partition (FM2b) | 103%, 12 errors (0.4%) | 7%, 179 errors | 7%, 189 errors |
| **region lost** (FM4) | **100%, 0 errors** | **2%** | **3%** |

Losing two of three clusters simultaneously cost **nothing measurable** on the
federated service. The two non-federated modes, same generator, same workload,
same instant, collapsed every time.

**The failure modes are silent in different ways, and error rate never catches
them.** Across every experiment, not one failure was detected by "something
returned an error":

- FM1a: the flat mirror served **17%** of its traffic with **one** error.
- FM2a: the flat mirror served **1%** with **zero** errors — a perfect SLO on a
  dead service.
- FM3: nothing errored, nothing went unready, no Kubernetes condition changed.
- FM2a recovery: ~5% of traffic in plaintext with errors at zero.

The mechanism is mechanical: a request with no endpoint never completes, and a
request that never completes never increments `response_total`. **Throughput,
membership and component health are the signals. Error rate is not.**

**Recovery is where the mesh actually breaks.** Failover was near-flawless every
time; coming back failed every time.

| run | unmeshed pods after recovery | plaintext during recovery |
|---|---|---|
| FM2a graceful | 6, then 4 more after remesh | ~5% of traffic |
| FM2b partition | 7 | 833 reqs (`api-east`) |
| FM4 region | **22** | **11971 reqs** (`frontend-federated`) |

Three for three, on BEL, under both fault variants. On `PROFILE=default` this is
not a rare race — it is the expected outcome of bringing a cluster back. And
**"restart the deployment to remesh it" reproduced the fault twice**, because
under `failurePolicy=Ignore` a restart is another roll of the same dice.
`PROFILE=production` is the actual fix and was not run.

The sharpest version, on clean counters: **zero plaintext through an entire
regional outage, 11971 plaintext requests on the way back.**

## Instrument defects found, in order of consequence

This run spent as much effort auditing the instrument as reading it, and that
was the right ratio.

1. **`adaptive_endpoints` is not a membership signal on BEL.** Three
   independent demonstrations in one day (FM3 dipped 9→5 under a latency-only
   fault; FM4 never converged while traffic said it had; an interrupted run left
   west reading 13 against 9 real pods). FM2 and FM4 both time convergence on
   it. Prefer the behavioural measure — traffic to the target stopping.
2. **The mTLS check reads a cumulative counter**, so every run inherits the
   plaintext of every run before it. This probably contaminated the published
   FM2-hard (2634) and FM4 (363) mTLS failures. Resetting counters first turned
   FM2-hard's mTLS check green while still showing the recovery plaintext —
   same conclusion, sound evidence.
3. **`CrossZoneTrafficAppeared` fired at rest**, saturated by the federating
   Prometheus's own cross-cluster scrapes. An alert already firing cannot report
   the event it exists for. Fixed and reloaded hot.
4. **FM1b's throughput denominator uses `SETTLE` instead of elapsed time**,
   reporting **113%** for traffic that was exactly nominal. Biases upward, which
   masks shortfalls. FM2 fixed this; FM1 did not.
5. **FM3's comparison checks measure end state, not peak** — reporting FAIL for
   the same widening the core check correctly reported as PASS — and assert
   widening on a mode that structurally cannot widen.
6. **FM3's contraction check accepts `active <= baseline`**, so a collapse to a
   single endpoint reads as healthy contraction.
7. **The 400ms brownout default is calibrated for a band this rig does not
   have.** Sized from the measured band (650ms), it peaked at 10.044 against
   8.00; the default is recorded as stalling at 7.85 twice.

## Two things that are still unexplained

- **The active pool baselines at 4, not 3**, and stayed there through six
  minutes of waiting with exactly three `Running` pods per cluster. `central`
  briefly reported **10** available against a real population of 9. This
  reproduces the 2026-08-17 note and remains open. It is not cosmetic: it sets
  the HAZL band, and the band decides whether FM3 produces a result at all.
- **Convergence timing did not distinguish the two FM2 variants** (1s graceful,
  0s partition, against a recorded OSS 6s/82s). Either HAZL genuinely steps off
  a partitioned cluster without waiting for timeouts, or `converge_by_traffic`
  registers trivially fast when HAZL is only using 3 endpoints. Re-running both
  variants on OSS in this rig would separate them.

## Not run

- **`PROFILE=production`** — the HA arm. Every claim here about control-plane
  outage severity and about unmeshed pods belongs to the defaults, not to a
  recommended production configuration.
- **FM5** (trust anchor) — the only failure domain with no failover target.
- **The Buoyant Cloud agent** — installed as a build step
  (`clusters/11-buoyant-agent.sh`) but not registered, so the external-observer
  contrast against in-cluster Grafana was not measured.


---

## Visualisation and export audit

Done after the runs, prompted by "did we export everything?" — and it found a
defect worth more than the export itself.

### Nothing was published until now

`docs/` — the GitHub Pages replay site — still held **feeds from 2026-08-26**
while every result in `results/` was from today. `task viz:build` is not run by
`task up` or by any runner, so a full day of experiments existed only as raw
snapshots. Rebuilt: **7 runs published, 0 skipped**, including `fm0-control`,
which the previous site did not carry at all.

### The published site labelled seven BEL runs as OSS

`viz/build.sh` wrote the index's flavor from **`$LINKERD_FLAVOR` in the shell
running the build**, not from the runs being published. `task viz:build`, in a
shell that had not exported it, defaulted to `oss`.

This is not cosmetic. `endpoints{ready}` means **the whole pool on OSS** and
**HAZL's active subset on BEL** (`verify/metrics.md`), so the flavor label
decides how every endpoint number on the page should be read. A BEL run
published as OSS is misread in a specific, confident, wrong direction — and it
is the same failure the `observer` file already exists to prevent.

Worse, the runners never recorded the flavor at all, so `build.sh` *could not*
have got it right. Fixed along the whole chain:

- every runner now writes `results/<run>/flavor` beside `observer`
- `viz/export.sh replay` emits it on each keyframe, so the page can display it
- `viz/build.sh` reads it **per run**, warns rather than guessing when absent,
  and the top-level `flavor` key is gone — it is a per-run property, and a
  single value is wrong the moment an OSS run is published beside a BEL one,
  which is exactly the comparison this rig exists to make

Today's seven runs were backfilled as `bel` and republished; the page now shows
`flavor` on replays, where it previously showed `—`.

### The mTLS panel could not distinguish a resolved incident from an ongoing one

The panel used a single `[5m]` window. We hit the consequence directly: after
remeshing, `increase[30s]` was already **0** while the wider window still read
elevated. On the 5m window alone, a resolved dip and an active breach look
identical for five minutes — and this panel is exactly what someone would stare
at during a game day.

Added a companion `[1m]` series, so:

- **1m clean, 5m depressed** → the incident is over, you are seeing its tail
- **both depressed** → it is still happening

Both series verified returning data; the dashboard gate now checks 26 queries
with 0 legitimately empty.

### Gap that cannot be retro-fixed: the live feed has no phases

The sampler ran for the whole session — **854 samples, 1.6 MB** — but
`task viz:phase` was never called, so every sample is `phase="unknown"`. The
live feed cannot show where a fault began or ended. The *replays* are unaffected,
because they are built from the `baseline` / `during` / `recovered` snapshots and
are phase-keyed by construction.

**For the next run: call `task viz:phase PHASE=injected` at injection and
`PHASE=restored` at restore**, or have the runners do it, the way they already
call `verify/annotate.sh` for the Grafana timeline. The annotation hook exists;
the viz phase hook was simply never wired to it.

### Standing note: `HAZLExpandedPool` is firing at rest

The post-run dashboard gate reports it as already firing before injection. It
self-baselines against the trailing 30 minutes, and the pool genuinely churned
through FM3 and FM4, so this is a true reading rather than a rule defect — it
should clear after 30 minutes of a stable pool. It is also downstream of the
unexplained active=4 baseline, and is worth re-checking once that is understood.


---

## The SLO foil: two of three stayed silent, and the third should have fired

`grafana/alert-rules.yml` carries three `origin=article` rules reproducing a
by-the-book SLO playbook, documented as **expected not to fire** during faults
that take a service down. Queried against the archived TSDB across the whole
session:

| rule | fired today? |
|---|---|
| `SLOAvailabilityBreach` | **no** |
| `SLOErrorBudgetFastBurn` | **no** |
| `SLORequestRateFloor` | **yes** |

Against **15 distinct `origin=mesh` alerts** that did fire.

The two **error-budget** rules stayed silent through a frozen control plane, two
cluster losses and a full region loss — which is the negative result the foil
exists to produce, now measured rather than asserted.

But `SLORequestRateFloor` **fired**, and that does not weaken the argument — it
sharpens it. A request-rate floor is a **throughput** alert. The thesis of this
whole exercise is that mesh-tier failures are caught by throughput, membership
and component health, and never by error rate. A rate floor catching them is the
thesis working, not the foil failing.

**The write-up should stop describing all three as the foil.** The foil is the
two error-based rules. `SLORequestRateFloor` is a correct mesh-tier alert that
happens to be wearing article clothing — and the fact that a by-the-book SLO set
contains one rule that works is a more interesting story than "none of them
worked."

## The Prometheus recording this exercise had no persistent volume

Found while archiving the data before teardown. `dr-prometheus` mounts exactly
two volumes, both configMaps. `/prometheus` is the container's writable layer, so
**any pod restart destroys every measurement in the run** — and nothing would
report that it had happened.

`--web.enable-admin-api` is also unset, so the TSDB snapshot API is unavailable,
and enabling it requires editing the Deployment — which triggers a rollout, which
destroys the data you were trying to snapshot.

The TSDB was copied out live (`tar` over `kubectl exec`, pod untouched) and
**verified by replay** rather than assumed: 617 metric names recovered, fault
windows visible in the throughput trace, 14 alerts queryable. See
`prometheus-archive/README.md`.

This is the FM4 observability lesson one level deeper: it is not enough for the
observer to sit outside the blast radius if the observer's *storage* does not
survive the observer. **Give `dr-prometheus` a PVC, or document that the run must
be archived before `task down`.**


---

## Fixed after the run: the replays could not make the page's own argument

Two gaps found by actually looking at the published site, plus a third the fix
exposed.

**`fm0-control` had no node address table.** Every other runner copies
`node-ips.txt` into its results directory; `fm0-control.sh` never did, so its
gateway lane reported `other 100%` instead of `east`. Unknown attribution, not
unknown destination — but fm0 is the run people open first, so it was the worst
one to leave looking like a hole in the data.

**No runner recorded node state, so "what Kubernetes says" was blank on every
replay.** That panel is the entire argument of the status page — the cluster tier
staying green while the mesh tier degrades — and it worked live and not in
recordings, which is how anyone reads a run afterwards. The page said so
honestly (*"node state was never written down"*), but honesty about a missing
measurement is not the measurement.

`record_node_state` now writes `<phase>.nodes` beside every metrics snapshot,
counted from `docker ps` rather than kubectl: during a partition the API server
does not answer, and "kubectl failed" and "the nodes are gone" are very
different claims. `viz/export.sh replay` emits a node count for **every**
cluster, not just the observer — node existence is knowable for all three, while
mesh state is only knowable for the one whose proxy metrics were captured.

Verified against a synthetic fixture (real metrics, invented node counts, in a
temp directory — never in `results/`):

| frame | cluster tier | page's verdict |
|---|---|---|
| baseline | all `Ready · 3/3` | "All clusters Ready. Mesh tier nominal." |
| during | `east NotReady · 0/3` | "The cluster tier can see this one." |
| recovered | all `Ready · 3/3` | "All clusters Ready. Mesh tier nominal." |

**And the fix exposed a false positive that had been hiding behind the blank
panel.** `anyMeshDegraded()` treated a source with no `status` as degraded —
and node-state-only entries carry no status, because a recorded run holds mesh
evidence for the observer alone. So every replay's *baseline* frame announced
*"Every cluster is Ready and the mesh tier is degraded"* about a perfectly
healthy rig. Absence of evidence read as evidence, in the one place this page
cannot afford to cry wolf. Fixed: undefined status now means no claim.

Runs recorded before this still render "not recorded", which stays honest. Runs
recorded after it show the contrast the exercise exists to demonstrate.
