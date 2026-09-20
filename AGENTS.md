# Working in this repo

This is a **measurement harness**, not a demo app. It builds three k3d clusters,
breaks the mesh on purpose, and records what happened. Almost every file here
exists to make a number trustworthy or to stop a wrong one being published.

That framing decides most questions. When in doubt, ask *"does this change what
we can honestly claim?"* rather than *"does this work?"*

## The Taskfile is the interface

```bash
task up                 # build everything; idempotent, finishes a half-built rig
task down               # destroy clusters and network (certs kept)
task fm0                # null experiment — certifies the instrument
task fm1 … fm5          # the failure modes
task verify             # every gate
task watch              # live cross-cluster traffic
task archive:save       # take the TSDB out BEFORE task down
task archive            # replay a run's Grafana offline
```

Drive it through `task`, and when you add a capability, add a task for it.
`ENFORCE_MESH` is the cautionary tale: it was documented in `clusters/lib.sh`
and referenced by nothing, so `ENFORCE_MESH=1 task up` silently did nothing and
no result taken under it was reproducible from the documented interface.

Config is environment: `PROFILE=default|production`, `LINKERD_FLAVOR=oss|bel`
(bel needs `$BUOYANT_LICENSE`), `OBSERVER`, `TARBALL`, `RELEASE`.

## Where the truth lives

| | |
|---|---|
| `clusters/lib.sh` | the one place clusters, regions, CIDRs, zones and workloads are defined. The k3d configs are **generated** from it — edit the table, never the YAML. |
| `verify/*.sh` | the gates. These exit non-zero; they are what a claim rests on. |
| `results/FINDINGS.md` | what each failure mode actually did. |
| `results/SHORTCOMINGS.md` | an honest audit of what the experiments do *not* establish. Read it before asserting anything. |
| `viz/`, Grafana | **lenses, not gates.** Never assert on them, and never quote a number from them that a runner disagrees with. |
| `CHARTS.md` | how anything that draws clusters, regions or zones orders them. Applies to Grafana panels, the status page and `diagrams/` alike. |

`grafana/README.md` covers opening the dashboard and reading it.

## Rules that are not style preferences

1. **Never commit a private key or a license.** `certs/*.key`, `settings.local.sh*`,
   `.env`. The trust anchor key is the root of the whole mesh's identity. Do not
   loosen `.gitignore` to make something convenient.

2. **Never rewrite `results/` or `docs/feeds/`.** Those files are the record of
   what was measured, in the vocabulary of the run that produced them — not
   documentation of the current topology. When the rig changes under a recorded
   run, the run does not get edited; it gets re-measured. `SHORTCOMINGS.md` § 16
   is the worked example.

3. **Do not "fix" the `origin=article` alert rules.** They reproduce a
   by-the-book SLO playbook verbatim and are *expected not to fire*. The
   negative result is the point.

4. **Do not quote a number that was not measured.** If a topology change
   invalidates a finding, say it needs re-measuring and link the section that
   says why. Deriving a fresh figure and presenting it as a result is the
   specific failure this repo is built to prevent.

5. **A selector that matches nothing must refuse to run.** Chaos Mesh reports no
   error for a selector matching zero pods, so a run looks clean having injected
   nothing. `clusters_in_region`, zone selection and the mesh-membership checks
   all guard this. Any new fault injection must too.

6. **Empty is the most expensive failure here.** An empty Grafana panel does not
   error and does not warn, and afterwards it is indistinguishable from "the
   experiment produced nothing". Two have already cost a run. `task
   verify:dashboard` exists for this; keep it passing.

## Shell conventions

Bash, `set -euo pipefail`, source `clusters/lib.sh`, and use its helpers rather
than reinventing them: `clusters`, `ctx`, `cluster_region`, `zones_for`,
`regions`, `federated_pool_size`, `retry`, `need`, and `log` / `ok` / `warn` /
`die`. `verify/lib.sh` adds the measurement helpers — `require_settled`,
`require_meshed`, `require_control_run`, `guard_blast_radius`, `mode_totals`,
`endpoint_pool`.

**The pipefail trap, which has now bitten this repo four times.** Under
`pipefail`, a reader that exits early or a glob that matches nothing promotes a
harmless status into a fatal one, and `set -e` kills the script *silently*:

```bash
workloads_in "$c" | grep -q app     # grep exits at match 1 → SIGPIPE → 141
ls -t dir/*.tar | head -1           # no match → ls exits 1 → whole pipeline 1
```

Read the value first and test it separately, or append `|| true`. It has
presented as "the app is in no clusters at all", as a cluster that *has* a zone
being reported as missing it, and as a script dying one line before it printed
the URL it existed to print.

Every step must be **idempotent** — `task up` on a half-built environment
finishes the job. And fail loudly or skip loudly; never skip silently. The
Buoyant agent skipping without credentials prints a full explanation, on purpose.

## Comments carry the why

This codebase comments unusually heavily, and the comments are not restating the
code — they record the failure that motivated it. `09-grafana.sh` explains why
`hostPath` and not a PVC (there is no provisioner, so a PVC hangs the build with
no error naming the cause). `archive-stack.sh` explains why the verification
query must be time-independent, with the measured decay that proved it.

If a line exists because something cost a debugging cycle, say what it was.
Match that density; a change that silently drops a "why" comment is a
regression.

## Commits

Subject names the change in plain words. Body is prose explaining **why**,
including what broke and how it presented. No bullet-point changelogs, no
`feat:` / `fix:` prefixes. Look at `git log` before writing one.

End with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## Layout

```
clusters/   00..12 build steps, 99 teardown; lib.sh holds the topology table
verify/     hard gates (non-zero exit); lib.sh holds measurement helpers
chaos/      failure-mode manifests and scripts
grafana/    dr-dashboard.json, alert-rules.yml, archive-stack.sh, README.md
diagrams/   excalidraw scenes — the editable source for the write-up's figures
load/       k6 scripts
viz/        status page over a snapshot feed; build.sh bundles runs into docs/
docs/       generated, committed — the published replay site
results/    FINDINGS.md, SHORTCOMINGS.md, run-*/SUMMARY.md (the rest is ignored)
```
