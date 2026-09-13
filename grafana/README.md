# The dashboard

The charts the write-up argues from. There are two ways to look at them, and the
short one needs no clusters at all.

| | | |
|---|---|---|
| **Read a recorded run** | 2 commands, ~2 min | Docker only |
| **Run the rig yourself** | `task up` | 3 k3d clusters, ~20GB Docker |

---

## A. Read a recorded run

```bash
task archive:fetch
```

```bash
task archive
```

That is the whole path. The first downloads a published run — an archived
Prometheus TSDB plus its fault annotations — into `prometheus-archive/`. The
second replays it against a throwaway Prometheus and Grafana in two Docker
containers. Nothing touches a cluster, and no cluster needs to exist.

It finishes by printing the link you actually want — roughly this, with your
run's own numbers:

```
  ok  704 distinct metric names recovered
  ok  3 fault annotations restored from annotations-sample-run-fm2-hard.json
  ok  grafana    -> http://localhost:50761  (anonymous admin)
  ok  data window -> 2026-09-08 14:31 .. 15:02 local

Open the dashboard already scoped to the run, so the panels have data:

  http://localhost:50761/d/dr-crosscluster/?from=1788861568000&to=1788863520000
```

**Use that URL, not the bare one.** The dashboard's time picker defaults to
`now-30m`, and an archive is by definition old, so opening it unscoped shows a
screen of empty panels — which looks exactly like a corrupt archive. The script
reads the run's real window off the data to spare you that.

```bash
task archive:down      # remove both containers
```

To replay a specific archive rather than the newest one on disk:

```bash
task archive TARBALL=prometheus-archive/tsdb-2026-09-08-1502.tar
```

## B. Run the rig yourself

Prerequisites and topology are in the [top-level README](../README.md).

```bash
task up             # three clusters, flat network, Linkerd, apps, load
task expose         # Grafana on a stable host port
```

→ **http://localhost:50760**, anonymous, no login. The dashboard is in the
**Disaster Recovery** folder.

Then, before you trust a single panel:

```bash
task verify:dashboard    # runs every panel's query, exits non-zero if any is empty
task fm0                 # the null experiment: no fault, certifies the instrument
```

Both are gates, not ceremony. An empty Grafana panel does not error and does not
warn, and afterwards you cannot tell it apart from *"the experiment produced
nothing"* — two of those have already cost runs here. `task fm0` establishes the
noise floor; nothing else does.

Now inject something:

```bash
task fm2 VARIANT=hard     # a partition, not a polite shutdown
```

And **before** `task down`, take your own archive:

```bash
task archive:save
```

That writes `tsdb-<stamp>.tar` and `annotations-<stamp>.json` into
`prometheus-archive/`, which is what path A replays. Skip it and the run's charts
die with the cluster — the numbers survive in `results/`, the charts do not.

---

## What you are looking at

Eight rows, in the order the dashboard presents them. Every row opens with its
own note, and every panel carries a description behind the ⓘ; this is the
reading order and the shape to expect.

First, **set `observed from` to match the experiment**: FM1 reads from
`central`, FM2 / FM3 / FM4 from `west`. It is the one control that silently
changes what every chart below it means.

### 1. Did anything alert?

Read this row first. An alert **absent** from the timeline never left Normal —
and for the three `origin=article` rules, that absence *is* the finding. They
reproduce a by-the-book SLO playbook verbatim and are expected not to fire.
See the header of [`alert-rules.yml`](alert-rules.yml).

### 2. Traffic — the money panels

The whole argument, in two charts side by side.

- **Throughput** — the federated service holds its rate flat through a cluster
  loss while the flat and gateway mirrors fall to near zero.
- **Errors** — almost nothing, on the same fault.

The gap between them is the result. A request with no endpoints hangs in the
balancer queue and increments no error counter, so a mode serving 2% of expected
traffic can look error-free. Every failure in this rig is caught by *"something
stopped"*, none by *"something returned an error"*.

### 3. The foil — what a by-the-book SLO would have said

Not the rig's health. **Availability holds near 100% while a mode sits at 2% of
expected**, for two reasons: a hung request lands in neither numerator nor
denominator, and it is measured inbound, so a dead cluster's proxies stop
reporting and the ratio is computed over the survivors.

The burn-rate rule needs ~52 seconds of solid 5xx to page. The request-rate floor
is the one that works — and its 5m window is still too slow for a 90s fault.

### 4. Latency and federation membership

Latency is FM3's only signal: a zone brownout fails nothing, so only the tail
moves. Read *which bucket*, not milliseconds — the buckets are coarse and
exponential.

Membership is the federation signal, and it is the cleanest number on the page:
**9 → 6** on cluster loss, **9 → 3** on region loss.

### 5. Where the traffic actually went

A dying cluster's line falls to zero while the survivors absorb its share.
Linkerd emits no cluster label for remote-discovery endpoints, so destination is
derived from the pod CIDRs (`10.21`=west, `10.22`=east, `10.23`=central).

Zone locality is a **cost** chart, and on open source nearly all of it is
expected to be cross-zone, not a bug: Linkerd balances zone-agnostically across
all 9 federated endpoints, and zones are region-scoped (`zone-a1..a3` in
region-a, `zone-b1..b3` in region-b), so a west client has exactly one
zone-local endpoint of the nine. The rest is cross-AZ egress you are paying for.

Do not quote a resting figure off this panel yet. It read ~1/3 local until
recently, and that was an artifact: every cluster labelled its nodes
`zone-a`/`zone-b`/`zone-c`, so west's `zone-c` and east's `zone-c` were the same
string and cross-*region* traffic was counted as zone-local.
[`SHORTCOMINGS.md` § 16](../results/SHORTCOMINGS.md) has the details and calls
for the re-measurement.

### 6. Zone-aware balancing — enterprise only

**Both panels are empty on open source, by design.** The proxy emits no HAZL
series at all. Re-record with `LINKERD_FLAVOR=bel` if you want this row.

The load band is not the documented 0.8/2.0 — those are per-endpoint, and the
exposed values are the pool aggregate — and it *moves* as the pool grows, which
is why it is plotted rather than assumed.

### 7. Invariants — these should never move

mTLS should be a dead-flat 100%. It is plotted over **two windows on purpose**: a
resolved dip looks identical to an ongoing one for a full five minutes on the 5m
series alone, so anyone reading this live during a game day would misjudge it.

Certificate headroom is how long a cluster keeps serving with `linkerd-identity`
gone. Measured at rest here: **23h50m**. That is the number that belongs in a
runbook.

### 8. Gateways

`gateway_alive`, from the service-mirror controllers — the metric nothing was
collecting, because linkerd-viz does not scrape `linkerd-multicluster` and the
admin port sits behind a default-deny policy. A flat (remote-discovery) link has
no gateway and reports 0 forever, so only links with `gateway_enabled=1` are
plotted.

---

## Three things that surprise people about a replay

**1. Instant queries read empty, and that is not a corrupt archive.** A PromQL
query evaluated at "now" only sees series with a sample inside the 5m staleness
window, so anything that counts series decays as real time passes. Measured on a
real archive here with an instant `count by (__name__)`: 617 series minutes
after it was taken, 271 eleven minutes later, falling from there — eventually to
zero, which is indistinguishable from a corrupt archive. `archive-stack.sh`
checks the label endpoint instead, which has no such window, so the count it
prints on startup is a different and stable number.

**2. Alerting → Alert rules is empty in a replay.** The throwaway Prometheus
loads no rule files, so nothing is listed. The alert **timeline** on the
dashboard still works: it is drawn from the `ALERTS` series Prometheus recorded
while the rules were firing, and those are in the TSDB like any other series.

**3. The red fault regions travel separately from the data.**
`verify/annotate.sh` writes them into Grafana's own database, not into
Prometheus, so they are not in the TSDB. `task archive:save` exports them beside
it and `task archive` posts them back. An archive taken before that existed
replays fine but comes up unshaded — the script says so rather than leaving you
to notice.

---

## This is a lens, not a gate

`verify/*.sh` are the things that exit non-zero. No number here should be quoted
anywhere the runners disagree with it.

- [`results/FINDINGS.md`](../results/FINDINGS.md) — what each failure mode did
- [`results/SHORTCOMINGS.md`](../results/SHORTCOMINGS.md) — what these
  experiments do *not* establish
- [`verify/metrics.md`](../verify/metrics.md) — which metrics exist in open
  source and which are enterprise-only

## Files

| | |
|---|---|
| `dr-dashboard.json` | the dashboard above; every panel binds to datasource uid `dr-prom` |
| `alert-rules.yml` | 8 recording rules, 21 alerts, and the foil |
| `archive-stack.sh` | replays an archived TSDB offline (`task archive`) |
| `prepare.py` | rewrites grafana.com dashboards for file provisioning |
| `vendor/` | Linkerd's own dashboards: 15474 Top Line, 15486 Health, 23979 HAZL |
