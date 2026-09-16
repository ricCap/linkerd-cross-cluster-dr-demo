# Vendored dashboards

Third-party Grafana dashboards, redistributed here so `task up` provisions them
without a network fetch. They are **not** this project's work.

| File | Dashboard | Publisher | Upstream source | Licence |
|---|---|---|---|---|
| `15474.json` | [Linkerd Top Line](https://grafana.com/grafana/dashboards/15474-linkerd-top-line/) | the [`linkerd`](https://grafana.com/orgs/linkerd/dashboards) org on grafana.com | [`linkerd2/grafana/dashboards/top-line.json`](https://github.com/linkerd/linkerd2/blob/main/grafana/dashboards/top-line.json) | [Apache 2.0](https://github.com/linkerd/linkerd2/blob/main/LICENSE) |
| `15486.json` | [Linkerd Health](https://grafana.com/grafana/dashboards/15486-linkerd-health/) | the [`linkerd`](https://grafana.com/orgs/linkerd/dashboards) org on grafana.com | [`linkerd2/grafana/dashboards/health.json`](https://github.com/linkerd/linkerd2/blob/main/grafana/dashboards/health.json) | [Apache 2.0](https://github.com/linkerd/linkerd2/blob/main/LICENSE) |

Both come from [linkerd/linkerd2](https://github.com/linkerd/linkerd2), which is
Apache 2.0 — the same licence as this repository. Copyright remains with the
Linkerd authors.

## These files are modified

`grafana/prepare.py` rewrites them before they are provisioned: it drops the
`__inputs` / `__requires` blocks and repoints every `${DS_PROMETHEUS}` reference
at this rig's datasource uid. Apache 2.0 § 4(b) asks that modified files carry
prominent notice of the change, and this is it. The rewrite happens at install
time and is not committed — what is in this directory is the unmodified
download, so a diff against grafana.com is meaningful.

## What is deliberately not here

The **Buoyant Enterprise for Linkerd HAZL** dashboard (grafana.com ID `23979`)
is not vendored. It is not part of the open-source Linkerd project — the
linkerd2 repository has no HAZL dashboard — it describes commercial software,
and no licence is stated for it anywhere. Redistributing it from an Apache-2.0
repository on that basis would be a guess.

`LINKERD_FLAVOR=bel` users can import it in a few seconds from the Grafana UI:
**Dashboards → New → Import → `23979`**, against the `dr-prometheus` datasource.
`clusters/09-grafana.sh` says so on the way out.

Nothing in this repo depends on it. The HAZL row of
[`../dr-dashboard.json`](../dr-dashboard.json) is this project's own work and
queries the proxy metrics directly.
