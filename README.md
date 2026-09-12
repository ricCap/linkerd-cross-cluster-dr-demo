# Cross-cluster disaster recovery: a testable mesh tier

A local test rig for running a **cross-cluster DR exercise** against Linkerd.
Three k3d clusters on a flat network, one workload exposed three different ways,
and chaos experiments that break the mesh on purpose so you can measure what
your DR plan actually does.

Most DR plans cover the data tier and the cluster tier. The mesh tier — the part
that carries traffic *while* you fail over — is rarely tested. This is that
test.

**[▶ Browse the recorded runs](https://riccap.github.io/linkerd-cross-cluster-dr-demo/)**
— the status page, replaying every experiment. No cluster needed.

## Quick start

You need Docker with **~20GB** allocated (the default 8GB is not enough), plus
`k3d`, `kubectl`, `helm`, `step`, `jq`, `task`, and the Linkerd CLI.

```bash
task up
```

```bash
task watch
```

```
== from west ==
  app-federated      4797 reqs  0 err  west=1710 east=1431 central=1656
  app-flat-east                4797 reqs  0 err  east=4797
  app-gateway-east-gw       4797 reqs  0 err  gateway/other=4797

endpoint pool (app-federated, ready)
  west      9
```

The 33/33/33 split and `endpoint pool = 9` are the baseline every experiment is
measured against.

## What it builds

| Cluster | Region | Nodes |
|---|---|---|
| `west` | `region-b` | server=`zone-b1`, agent-0=`zone-b2`, agent-1=`zone-b3` |
| `central` | `region-a` | server=`zone-a1`, agent-0=`zone-a2`, agent-1=`zone-a3` |
| `east` | `region-a` | same as central — one region, shared zones |

`east` and `central` share a region on purpose, so "region failure" really means
losing two clusters at once rather than one cluster with a new label.

`west` sits alone in `region-b` because **no experiment may touch it**. It runs
Grafana and the Prometheus that federates all three clusters. An earlier layout
had the region experiment destroying the cluster doing the recording.
`verify/fm4-verify.sh` now refuses to run if the observability stack is inside
the target region.

One `podinfo` workload, exposed three ways, so a **single** fault gives you
three results you can compare directly:

| Service | Mode | Label |
|---|---|---|
| `app` | federated | `mirror.linkerd.io/federated=member` |
| `app-flat` | flat mirror (pod-to-pod) | `mirror.linkerd.io/exported=remote-discovery` |
| `app-gateway` | gateway mirror | `mirror.linkerd.io/exported=true` |

`clusters/lib.sh` is the one place cluster names, regions and CIDRs are defined.
The k3d configs are generated from it — edit the table, not the YAML.

## The five experiments

Each runner takes a baseline, injects the fault, measures, restores, and exits
non-zero if a check fails.

| | Fault | Target | What dies | Kubernetes says |
|---|---|---|---|---|
| `task fm0` | *none* | — | nothing | nothing |
| `task fm1` | control plane | `central` | nothing | nothing |
| `task fm2` | cluster | `east` | 3 of 9 endpoints | cluster gone |
| `task fm3` | zone brownout | one zone, every cluster | nothing | nothing |
| `task fm4` | region | `region-a` = `east` + `central` | 6 of 9 endpoints | clusters gone |
| `task fm5` | trust anchor | `east` | nothing, at first | nothing |

Three of the five rows say Kubernetes notices nothing at all. That is the point:
every pod stays `Running` and every cluster-level dashboard stays green.

```bash
task fm2 VARIANT=hard     # a partition, not a polite shutdown
task fm1 MODE=identity    # cert headroom, and the scale-up a failover needs
task fm1 MODE=mirror      # break the CROSS-cluster control plane, local one fine
task fm5 MODE=anchor      # a rotation that finishes in one cluster and no other
```

Results land in `results/<profile>/<run>/`, so the two profiles never overwrite
each other. Every runner refuses to start unless `task fm0` has certified the
instrument for that profile, the rig has settled, every pod is meshed, and the
mesh's own view of the federated service is the right size.

**Run `task fm0` before any run that matters.** The null experiment injects
nothing, measures everything, and checks that the instrument reads clean.
Nothing else here establishes the noise floor. It is not theoretical: an early
throughput calculation reported 190% of expected for a service that was simply
healthy, caught only because the number looked odd.

**Run `task verify:dashboard` too.** An empty Grafana panel does not error and
does not warn, and afterwards you cannot tell it apart from "the experiment
produced nothing". Two empty panels have already cost a run. This task runs
every panel's query and exits non-zero if any comes back empty. It also catches
a cold Prometheus, whose under-filled 15m baseline hides exactly the collapse
the alerts exist to catch.

## Configuration

```bash
task up                      # PROFILE=default    Linkerd's out-of-the-box settings
PROFILE=production task up   # HA control plane + mesh membership enforced

LINKERD_FLAVOR=oss task up   # default
LINKERD_FLAVOR=bel task up   # needs $BUOYANT_LICENSE
```

Every result in `results/` was taken on `default` — a single-replica control
plane with the default admission policy — and that choice **produces** findings
rather than just hosting them. FM1 scales `linkerd-destination` to zero, which
on a single replica is a total outage and on HA is the exact event HA exists to
absorb. The silent-unmeshed-pods finding exists *because* the default is
`failurePolicy=Ignore`.

Neither profile is a superset of the other, so run both. Claims of the form
"here is what a mesh does in a disaster" belong to `production`; `default` shows
what the defaults cost you.

Open source covers the cluster, region, and control-plane failure modes. HAZL
(zone brownout, `task fm3`) and the 2.20 trust anchor rotation operator are
enterprise features — [`verify/metrics.md`](verify/metrics.md) lists exactly
which metrics exist in each.

## Watching it happen

`task watch` is the terminal view. The status page shows the same topology,
animated, with the cluster-tier status strip next to the mesh-tier numbers so
you can watch one stay green while the other does not:

```bash
task viz:sample                    # one terminal: sample the live mesh
task viz                           # another: serve at localhost:8731
task viz:replay RUN=fm2-graceful   # or replay a finished run
```

`task viz:build` bundles every recorded run into `docs/`, which is what the
[published site](https://riccap.github.io/linkerd-cross-cluster-dr-demo/)
serves.

The page is a **lens, not a gate**: `verify/*.sh` are the things that exit
non-zero. See [`viz/README.md`](viz/README.md) for the feed format.

## The Grafana dashboard, without building anything

The status page is the topology. The Grafana dashboard is the measurement — the
charts every claim in `results/` is read off. It normally lives in a Grafana
inside `west`, which means `task down` destroys it.

You do not need a cluster to look at one:

```bash
task archive:fetch    # a recorded run: its Prometheus TSDB and fault annotations
task archive          # replay both against a throwaway Grafana on :50761
```

Two Docker containers, no k3d, about two minutes. `task archive:down` removes
them. On a live rig it is `task expose` and <http://localhost:50760> instead —
and `task archive:save` **before** `task down` is how you keep a run's charts.

[`grafana/README.md`](grafana/README.md) is the guide: both paths, then what
each row of the dashboard means and what shape to expect from it.

## Results

- [`results/FINDINGS.md`](results/FINDINGS.md) — what each failure mode actually did
- [`results/SHORTCOMINGS.md`](results/SHORTCOMINGS.md) — an honest audit of what these experiments do *not* establish
- `results/run-*/SUMMARY.md` — per-run reports

`grafana/alert-rules.yml` holds 8 recording rules and 21 alerts: at least one per
failure mode, plus a deliberate foil. The organising finding is that every
failure here is caught by *"something stopped"* or *"something is unreachable"*,
and **none** by *"something returned an error"*.

The three `origin=article` rules copy a by-the-book SLO playbook word for word
and are **expected not to fire**. That negative result is the point, so don't
"fix" them. The file's header comment carries the rest, including why a
90-second fault cannot fairly test a `for: 2m` rule.

## Layout

```
clusters/   00..12  build steps, 99 teardown; lib.sh holds the topology table
verify/     flat-network.sh, multicluster.sh   hard gates (non-zero exit)
            dashboard.sh                       proves every panel returns data
            watch.sh                           live traffic view
            metrics.md                         proxy metrics pinned from a live proxy
load/       k6 scripts: steady.js, ramp.js
chaos/      failure-mode manifests and scripts
grafana/    dr-dashboard.json, alert-rules.yml
            archive-stack.sh                   replays a run's charts offline
            README.md                          how to open it, and how to read it
viz/        export.sh + index.html             status page over a snapshot feed
            build.sh                           bundles recorded runs into docs/
docs/       generated, committed               the published replay site
```

## Three things that will bite you

None of these fail loudly.

**1. Flat networking needs three ingredients, not one.** A shared Docker
network, *non-overlapping pod and service CIDRs per cluster*, and a static route
mesh installed inside every node container. `verify/flat-network.sh` proves
pod-to-pod reachability across every ordered pair of clusters — routes existing
is not the same as traffic flowing.

**2. Flat mirroring uses a different label than you think.**
`mirror.linkerd.io/exported=true` selects **gateway** mirroring. Pod-to-pod flat
mirroring needs `exported=remote-discovery`. Get it wrong and you get no mirror
at all, with no error anywhere.

**3. Two links to the same cluster double-count federation.** Every Link carries
a `federatedServiceSelector`. `west` has two links to `east`, so leaving the
default on both makes east's pods appear **twice**: 12 endpoints instead of 9, a
silent 25/50/25 baseline, and every number derived from it wrong.
`verify/multicluster.sh` asserts endpoint counts specifically to catch this.

Related: `linkerd multicluster check` reports two failures here that are **not**
real. It runs on the host, but `--api-server-address` points at Docker-network
IPs only containers can reach. Trust `verify/multicluster.sh`, which tests
behaviour rather than the host's routing table.

## Credits

The flat-network approach — per-cluster CIDRs plus the `jq` + `docker exec`
route mesh — comes from Buoyant's
[k3d-multicluster-playground](https://github.com/BuoyantIO/k3d-multicluster-playground)
(itself derived from work by alpeb and olix0r), generalised here from two
clusters to N. That repo is a HAZL demo; this one is a DR harness, so the rest
is new.

## License

[Apache 2.0](LICENSE).
