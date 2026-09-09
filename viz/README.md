# Status page

A static page over a JSON snapshot feed. The same page serves a live game day
and a replay of a recorded run — only the feed differs.

```bash
task viz:sample     # one terminal: sample the live mesh
task viz            # another: serve the page at localhost:8731
```

```bash
task viz:replay RUN=fm2-graceful    # build a feed from results/fm2-graceful
```

## This is a lens, not a gate

`verify/*.sh` are the things that exit non-zero. Nothing here is ever asserted
on, and no number on the page should be quoted anywhere the runners disagree
with it.

## The feed

`viz/export.sh` is the only thing that touches a cluster. It writes NDJSON — one
sample per line — and the page reads nothing else.

| Field | |
|---|---|
| `phase` | set by `task viz:phase PHASE=injected` |
| `topology`, `zones` | straight from `clusters/lib.sh`, so the page never hardcodes a picture of the rig |
| `observer` | whose proxy metrics these are |
| `node_table` | false when gateway endpoints cannot be attributed — see below |
| `sources.<cluster>.status` | `up`, `unreachable`, or `down` |
| `sources.<cluster>.modes.<mode>` | `reqs`, `errors`, `nontls`, `dist`, `pool`, `active` |

### Rates, never counters

A sample carries the **delta** since the previous one. `verify/lib.sh` explains
why: proxy counters only ever go up, so during an outage the raw distribution
still shows a large count for the dead cluster — all of it banked before the
fault. Animating that would say "the dead cluster is still serving traffic", in
colour, ten times a second.

Deltas are per series, keyed on the full label set, over series present in both
dumps. That is the fix for the bug that produced `app-flat-east -5381 reqs` in
`results/run-2026-08-17/SUMMARY.md`: summing whatever series exist in each
snapshot subtracts a population that has since been evicted.

A series that is present now and absent before counts **in full**. A proxy
series starts at zero when its first matching response creates it, so all of it
accrued inside the window. Dropping it would under-report exactly where it hurts
most: after a recovery every pod is new, so a restored cluster would read as
serving nothing.

The exception is the first sample of a session. Every series is new there, but
its counter holds the whole proxy uptime, so that sample is marked `warmup` and
reports zero.

### Liveness has five states, and one of them is the point

| | |
|---|---|
| `up` | metrics answered |
| `unmeshed` | pods Running and Ready with **no linkerd-proxy** |
| `silent` | proxy is there and is not answering |
| `unreachable` | nodes running, API unreachable — partitioned |
| `down` | no nodes running |

`down` and `unreachable` are separate because that is the distinction FM2's two
variants exist to draw. A graceful `docker stop` leaves no container; a hard
partition leaves every container running and unreachable.

`unmeshed` is the one that matters. A cluster can come back from a restart with
every workload Running, Ready, and outside the mesh: pods admitted while the
proxy-injector was down never get a proxy, and nothing retries. No proxy means
no proxy metrics, so the sampler sees silence from a cluster that is in perfect
health at the cluster tier. Calling that `unreachable` would tell you the
opposite of the truth — it would read as an outage when the cluster is up and
quietly unencrypted.

This happened on the first FM2 run against a live rig, which is why the state
exists here at all.

The check is narrow on purpose. It asks whether the **load generator** has a
proxy, because that is what the sampler reads from. It is not a mesh-membership
audit — `verify/meshed.sh` is the gate for that, across every namespace — and
nothing here should be used in its place.

### Windows are measured, not assumed

Each sample carries the actual elapsed seconds since the previous one, to two
decimals, and every rate divides by that rather than by the nominal interval.

A tick is `sleep $INTERVAL` plus however long the sampling took — three
`proxy-metrics` calls, about a second. Dividing a 5.9s window by a nominal 5
reported **34 rps against a load generator configured for 30**. Rounding the
same window to a whole 6 reported 28.7. At a 5s tick, one second of rounding is
a 17% error, so the correction and the error were the same size. Both look like
plausible numbers, and the only thing that catches either is checking a total
against the configured RPS.

Clusters are sampled in parallel. Done one at a time, a single wedged cluster
adds its whole timeout to every tick — the sampler would slow down precisely
when something is wrong, which is when you are watching it. Each fetch is
bounded by `FETCH_TIMEOUT` (default 6s), because `proxy-metrics` against a
wedged cluster does not fail, it hangs.

### Colour

Three hues, one per exposure mode, roughly 175° / 265° / 40° apart: teal,
indigo, amber. None of them is red, because red already means errors, and grey
already means idle.

Within a lane, destination buckets are shaded rather than given new hues.
Colouring them from the lane palette put two meanings on one channel — hue
meaning "exposure mode" on the arcs and "which cluster" in the bars. Every
segment in a bar belongs to the same lane, so a lightness ramp is enough, and
the source's own bucket sorts first at full strength.

### What the topology shows

A column per workload, a row per zone, so the picture shows the app rather than
just the rig:

| Workload | Mode | Where |
|---|---|---|
| `frontend` | federated | every cluster |
| `api` | flat mirror | every cluster |
| `analytics` | gateway mirror | **east only** |

That last row is why the gateway lane always points at east, and it used to be
invisible: the page drew one dot per zone, which quietly showed the federated
workload's replicas alone. West and central run six pods, east runs nine, and
the picture showed three.

Arcs leave and land on the **column of the workload that serves that lane**, so
a flat-mirror arc points at the `api` pods on the other end rather than at the
cluster in general. Gateway arcs land on the gateway chip instead, because a
gateway mirror resolves to the target cluster's node addresses and the gateway
forwards from there. That hop is real and worth drawing.

The layout comes from `WORKLOAD_TABLE` in `clusters/lib.sh`, which
`clusters/06-apps.sh` also deploys from. A second copy of that list is how the
load generator ended up driving one service while the runner measured another.

### Narrow screens get a different layout, not a smaller one

Below about 620px of container width the clusters stack vertically in a ~380-unit
viewBox instead of sitting side by side in a 960-unit one.

Scaling the wide layout down does not work, and the numbers say why. Fitting 960
units into a phone's ~347px is a scale of 0.35, so a 9.5-unit label renders at
**3.3px**. Type large enough to read inside a 960-unit box would need a ~1100px
container, which a phone does not have. Stacked, the scale is ~0.91 and labels
land at 10px and up.

Arc depths are **spread across** the right-hand gutter rather than added up per
route, so the viewBox stays a fixed 380 units whatever the feed contains. Adding
them up meant a run with more routes widened the box, which scaled every label
down — a feed with a dozen routes would have quietly undone the layout.

The layout is chosen from the container's measured width, not the viewport, so
the diagram is right inside whatever column it is placed in.

### Reading it without the picture

The table lives in its own `overflow-x` container, and the grid track it sits in
is `minmax(0,1fr)` rather than `1fr`. That distinction carries weight: a bare
`1fr` means `minmax(auto,1fr)`, whose floor is the column's **min-content**
width, and the table sets `white-space:nowrap` on its cells. Opening it
therefore widened the whole column — diagram included — past the viewport. The
wrapper's own `overflow-x` could not help, because the blow-out happened a level
above it in the grid track.

`Traffic as text` under the diagram lists every active route with its measured
rate. It is not an accessibility afterthought: the per-arc tooltips are SVG
`<title>` elements, which need a hover, so on a touch screen it is the only way
to read a route at all.

The diagram's `aria-label` is regenerated per sample — it used to be a fixed
string that never described what was on screen. One `aria-live` region announces
phase and health changes only; putting every figure in it would make a live feed
unusable with a screen reader on.

Colours clear WCAG AA against the card surface: 4.6 for the dead-cluster grey
(it was 2.58), 3.0 for the idle-wiring grey as a graphical object, and 5.3–8.1
for the three lanes.

### Every cluster is a source

The load generator runs in every cluster on purpose. FM4 takes out two clusters
at once, so load driven only from `west` would stop the experiment rather than
measure it. Each generator's own proxy is its measurement surface, and the page
draws all of them: one card per cluster, and one arc per observed route leaving
the cluster whose generator sent the request.

That is what makes a failure visible rather than merely absent from a table. In
FM2 you watch `east`'s generator go dark while the survivors carry on. In a
replay, clusters that were never recorded say so instead of reading as dead.

Each distribution marks the source's own bucket `(local)`, because "how much
stayed in this cluster" is the comparison the federated mode exists to make.

Routes are **discovered from the feed**, not listed in advance. The full cross
product is 27 arcs and most of it never exists — a flat mirror resolves to
exactly one cluster, and `east` carries no gateway link at all. Drawing only
what has been observed keeps the picture to the dozen or so links that are real.
A link that goes quiet during a failure keeps its place rather than vanishing,
which would read as the topology changing.

### Modes are per-cluster

The lane list comes from `modes_for` in `clusters/lib.sh`, not from a hardcoded
triple. `east` resolves `app-flat-west` rather than `app-flat-east`, and only
clusters carrying a gateway link resolve a `-gw` mirror at all. A lane the page
shows as *not resolvable* is a different fact from a lane at zero traffic.

### `other` in a distribution

Gateway mirrors resolve to a **node** address, not a pod IP, so attributing them
needs the node table `save_node_ips` writes to `clusters/.generated/`. Without
it they fall into `other`, and the page says so — unknown attribution is not the
same as unknown destination.

## Replaying a recorded run

A recorded run holds three snapshots, so a replay is three **keyframes**, not a
timeline. The page labels them that way rather than implying it interpolated
something nobody measured. Window lengths come from file mtime, which is the
real wall-clock spacing of the run.

Runs recorded before the runners started writing an `observer` file need one
supplied, because the runners deliberately disagree: FM1 reads the cluster whose
control plane it breaks, the others read a surviving observer.

```bash
OBSERVER=central task viz:replay RUN=fm1-identity
```

Getting that wrong is silent. Mirror service names differ per cluster, so the
wrong observer measures a service that was never exercised and reports it as
zero traffic — which looks exactly like a mode that died.

## Publishing replays

```bash
task viz:build     # regenerate docs/
task viz:site      # preview it at localhost:8732
```

`docs/` is a self-contained static site: the page, one NDJSON feed per recorded
run, and a manifest the page turns into a run selector. About 64KB in total.

To serve it, go to the repository's **Settings → Pages** and set *Source* to
**Deploy from a branch**, branch `main`, folder `/docs`. No workflow and no
Actions permissions are needed, because the feeds are committed rather than
built in CI. Publishing is a deliberate step — nothing here does it for you.

Each run gets its own URL (`?feed=feeds/fm2-graceful.ndjson`), so you can link
to a specific result from the write-up.

### Why the feeds are committed

Generated artifacts otherwise stay out of this repo — `results/*` is ignored
precisely so run output does not pile up in history. Two things make these the
exception.

The raw snapshots are gitignored, so nothing in CI could rebuild them. And a
replay's window lengths come from the snapshot files' **mtimes**, which are the
real wall-clock spacing of the run and the only record of it, since the
`.metrics` files carry no timestamps. git does not preserve mtime, so that
timing exists on exactly one machine until the feed is written. Committing the
feed preserves it; committing the raw snapshots would not.

A feed is closer to a measurement than to a build product, which is why it
belongs in the repo for the same reason `FINDINGS.md` does.

### Runs without provenance are not published

`viz/build.sh` skips any run with no `observer` file rather than guessing one,
and tells you what to do about it. Publishing a run measured from the wrong
cluster would be worse than publishing nothing: mirror service names differ per
cluster, so the wrong observer measures a service that was never exercised and
publishes it as zero traffic — which looks exactly like a mode that died.

The same reasoning applies to the node table, which is why the runners now copy
it next to the snapshots. Attributing an old run's gateway endpoints with a
current table is not a small error but a confident wrong answer: Docker assigns
those addresses and they change across rebuilds, so a `172.28.0.7` that was
`east` last week can be `central` today. A run that recorded no table reports
`node_table: false`, and the page says attribution is unavailable.

### Zero is not the same as dead

A lane that carried nothing *at any point in a recording* was never driven by
the load generator — it did not fail. The page tells the two apart and says
which is which, because confusing them inverts the result.

This is not hypothetical. FM1 kills nothing at all, and in the pre-`modes_for`
recordings its gateway lane sits at flat zero because the generator drove one
service while the runner measured another. Reported as a silent failure, that
would publish the exact opposite of what the experiment found.

## What has been tested

Against a live three-cluster rig (OSS, `task up`), through a full
`task fm2 VARIANT=graceful` cycle: steady state, injection, convergence,
restore, and the unmeshed recovery that followed.

The exporter's numbers were checked against the runner's own results table for
the same window and agree exactly — federated 3125 reqs, flat 54, gateway 151
with 116 errors — and against the configured 30 rps per generator, which is what
caught the window bug above.

Replay is exercised against every recorded run in `results/`. Both paths share
one parser, so the arithmetic is covered by either.

Not tested: FM1, FM3 and FM4, and the BEL flavour — so the HAZL fields
(`active`, `load`, `band`) have only ever been null here.
