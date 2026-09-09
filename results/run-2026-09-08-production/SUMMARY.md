# Arm B — 2026-09-08, `PROFILE=production`

**The first time this repo has ever run the production profile.** Every claim
previously made about it was a prediction; two of them were wrong.

HA verified in force before measuring, not assumed:

```
west/east/central   linkerd-destination=3/3  linkerd-identity=3/3  linkerd-proxy-injector=3/3
                    failurePolicy = Fail
                    dr-demo       = all-authenticated
```

125 pods across three clusters, no evictions, no OOMKills. `fm0` passed 6/6 at
99% of nominal.

## Status

| | Experiment | Result |
|---|---|---|
| FM0 | control, no fault | **6/6** |
| FM1b | identity down | **3/3** |
| FM2a | cluster loss, graceful | **6/6** |
| FM2b | cluster loss, hard partition | **6/6** |
| FM4 | region loss | **6/6** |

FM1a, FM1c and FM3 were not re-run here. FM1a and FM3 are insensitive to the
profile by this repo's own analysis, and FM1c's result is about which component
owns federated membership, which `failurePolicy` does not touch.

## The headline: the recovery failure is gone

This exercise's most valuable finding is that a recovered cluster brings
workloads back **outside the mesh** — `Running`, `Ready`, passing health checks,
serving cross-cluster traffic in plaintext with authorization unenforced. On
`PROFILE=default` it reproduced on **three recovery attempts out of three**.

Under `failurePolicy=Fail`, across the same three recoveries:

| Recovery | Arm A (`Ignore`) | Arm B (`Fail`) |
|---|---|---|
| FM2a graceful | unmeshed pods, ~5% of traffic plaintext | **0 unmeshed** |
| FM2b partition | unmeshed pods; 469 plaintext contaminated the next run | **0 unmeshed** |
| FM4 region | **22 unmeshed pods, 11971 plaintext requests** | **0 unmeshed** |

Verified independently of the runners: `verify/meshed.sh` reports every pod
meshed across all three clusters, and the proxy counter holds **zero** non-mTLS
series for `app-federated` and `app-flat-east` — against 133 accumulated series
by the same point in Arm A.

**And it costs nothing during the outage.** Failover was unchanged: FM2a 6/6 at
100%, FM2b 6/6 at 101%, FM4 6/6 with 0 errors of 3347, and zero non-mTLS in all
three. The trade is not "safety for availability during a disaster" — it is
"safety for the ability to create pods while the injector is down", which is a
much narrower price than the write-up implies.

## What was wrong: `failurePolicy` does not change how FM1b fails

`SHORTCOMINGS.md` §11 and both prior run summaries state that under
`production` the pods FM1b cannot start *"would be rejected at admission
instead of stalling in init"*.

**They still stall in init.** Same `Init:1/2`, same three pods, `readyReplicas`
stuck at 3 of 6 for the full 120s — indistinguishable from the default arm.

The claim conflated two components:

| what is down | admission | outcome |
|---|---|---|
| **proxy-injector** | webhook unreachable → `failurePolicy` decides | `Ignore` admits **unmeshed**; `Fail` **rejects** |
| **identity** (what FM1b breaks) | webhook **healthy**, proxy injected fine | pod admitted **with** a proxy that cannot get a cert → `Init:1/2` |

FM1b scales `linkerd-identity` to zero and leaves the injector at **3/3**, so
admission succeeds and the sidecar *is* injected — `Init:1/2` means
`linkerd-init` completed and `linkerd-proxy` did not. `failurePolicy` governs an
unreachable webhook. It has nothing to say about a proxy that was injected
correctly and then could not reach identity.

**So the silent-security-vs-loud-availability trade is real but narrower than
written.** It applies to the injector, which is the unmeshed-pod finding. It
does not apply to identity loss: under *both* profiles, losing identity blocks
the scale-up your failover depends on, in exactly the same silent way, with
pods that never become ready and never alert.

That is a sharper result than the prediction it replaces: **the hardening knob
does not help with the failure mode that most directly breaks a failover.**

## Certificate headroom is still the clock

**22h17m** minimum across the data plane, measured from the certificates rather
than assumed from the nominal 24h lifetime. HA does not change it — three
identity replicas issue the same 24h leaf certificates as one, and when all
three are gone the countdown is identical.

## A data-handling defect this run exposed

**Arm B overwrote Arm A's raw snapshots.** Both write to `results/fm2-graceful`,
`results/fm4` and so on, so running the second sweep destroyed the first
sweep's metric files. The numbers survive — they are in the two SUMMARY.md
files and in the archived TSDBs — but the raw evidence for Arm A's FM0, FM1b,
FM2a, FM2b and FM4 is gone.

Worse, nothing recorded which profile a run used, so the published replays were
ambiguous in a way that matters: on `default` an unmeshed recovery is the
*expected* outcome, on `production` it is a regression. That is the same defect
as the 2026-08-27 site publishing seven BEL runs labelled OSS — a run read
under the wrong identity is misread confidently, in a specific direction.

Every runner now writes `profile` beside `flavor`, and `viz/build.sh` reads it
per run and warns rather than guessing when it is absent. The existing runs
were backfilled from what is knowable: FM1a, FM1c and FM3 are Arm A, because
Arm B did not re-run them; the other five are Arm B.

**The collision itself is not fixed.** Until results are namespaced by profile,
the durable record of a sweep is its `SUMMARY.md` and its TSDB archive, not the
snapshots — and running two arms back to back costs you the first one's raw
data.

## For the write-up

Both arms are now measured, and the recommendation is stronger than it was:

> Set `failurePolicy=Fail`. It eliminated the recovery failure on three of three
> attempts, cost nothing during three separate outages, and the price is
> narrower than it sounds — you cannot create pods while the injector is down,
> which is not the same as being unable to fail over.
>
> It will not save your failover scale-up. That needs identity, and identity
> loss looks identical under both profiles.
