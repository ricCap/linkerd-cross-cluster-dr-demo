# Pinned proxy metrics

Captured from a **live** Linkerd proxy in this environment, not from
documentation. Linkerd's proxy metric surface changes between releases and the
docs lag it, so everything below was verified with:

```bash
linkerd --context=k3d-west diagnostics proxy-metrics -n dr-demo deploy/loadgen
```

Proxy build: `linkerd2_proxy 2.364.0`, CLI `edge-26.8.1`, OSS flavor.

---

## BEL adds these (verified on enterprise-2.20.1)

Re-captured against a Buoyant Enterprise control plane installed with
`-ext-endpoint-zone-weights`. The HAZL metrics exist and carry live values:

| Metric | Meaning |
|---|---|
| `outbound_http_balancer_adaptive_load_average` | latency x throughput for the active pool |
| `outbound_http_balancer_adaptive_load_band_low` | withdraw-endpoints threshold |
| `outbound_http_balancer_adaptive_load_band_high` | add-endpoints threshold |
| `outbound_http_balancer_adaptive_endpoints` | endpoints **available** |

**The band is emitted, so read it rather than assuming it.** It is *not* the
documented 0.8 / 2.0 — those are per-endpoint, and the exposed values are the
aggregate for the active pool (measured: exactly `0.80 x active` and
`2.00 x active`). See `results/FINDINGS.md`.

### `endpoints{ready}` means something different under BEL

This one silently breaks assertions written against OSS:

| | OSS | BEL |
|---|---|---|
| `adaptive_endpoints` | absent | 9 — all endpoints available |
| `endpoints{endpoint_state="ready"}` | 9 — the whole pool | **3** — the subset HAZL is using |

On OSS, `endpoints{ready}` is the federation membership signal. On BEL it is the
zone-local active subset, so a baseline assertion of "9 endpoints" fails for a
reason unrelated to federation. `verify/lib.sh` prefers `adaptive_endpoints`
when present and falls back to `endpoints{ready}`, so the same check works on
both flavors.

---

## The one that isn't there

`outbound_http_balancer_adaptive_load_average` — named in Buoyant's HAZL tuning
guide as *the* metric for observing the load band — **does not exist in the open
source proxy.** Zero series. It is a Buoyant Enterprise addition, which is
consistent with HAZL being an enterprise feature, but it means:

- FM3's HAZL band-walk verification **requires** `LINKERD_FLAVOR=bel`.
- On OSS, the closest available signal is `outbound_http_balancer_endpoints`
  (below) — it shows the endpoint pool *changing size*, which is the observable
  consequence of HAZL expanding, even though the load average driving it is not
  exposed.

Re-verify this against a BEL proxy before writing the HAZL section of the post.

---

## Metrics the experiments actually use

### `response_total` — the workhorse

One counter per (destination endpoint × status × TLS state). Labels present:

| Label | Example | Used for |
|---|---|---|
| `authority` | `app-federated.dr-demo.svc.cluster.local:9898` | which exposure mode |
| `target_ip` | `10.22.1.6` | **which cluster served** — see note below |
| `tls` | `true` | mTLS continuity |
| `server_id` | `default.dr-demo.serviceaccount...` | peer identity |
| `dst_zone` | `zone-b` | zone attribution |
| `dst_zone_locality` | `local` / `remote` / `unknown` | blast-radius containment |
| `status_code`, `classification` | `200`, `success` | error budget |
| `dst_target_cluster` | `east-gw` | **gateway mirrors only** |

**There is no cluster label on federated or flat-mirror traffic.** Linkerd only
emits `dst_target_cluster` for gateway-mirrored destinations. For remote
discovery the pod IP is the only identifier, so we map `target_ip` against the
pod CIDR table in `clusters/lib.sh` (`10.21.` → west, `10.22.` → east, `10.23.`
→ central). Both `verify/watch.sh` and `verify/multicluster.sh` do this.

### `outbound_http_balancer_endpoints` — federation membership

```
outbound_http_balancer_endpoints{endpoint_state="ready",parent_name="app-federated",...} 9
```

The size of the load balancer's endpoint pool, split by `endpoint_state`
(`ready` / `pending`). This is the **direct, live signal for federated service
membership** and the cleanest way to time convergence in FM2/FM4: watch it drop
9 → 6 when a cluster dies and recover when it returns. Works in OSS.

### `control_identity_cert_expiration_timestamp_seconds` — certificate headroom

```
control_identity_cert_expiration_timestamp_seconds 1786463078.0
```

Unix timestamp at which this proxy's workload certificate expires. Subtract
`time()` for remaining headroom. This is the metric behind the post's
"certificate headroom" row, and it is what makes FM1b measurable rather than
theoretical: it says exactly how long a running proxy can survive with
`linkerd-identity` down.

Companions: `control_identity_cert_refreshes` (counter) and
`control_identity_cert_refresh_timestamp_seconds`.

---

## What the SLO-foil and latency panels depend on

Captured live via `verify/dashboard.sh` and direct queries against the
federating Prometheus, OSS flavor, healthy rig. All three assumptions held.

| Assumption | Verdict |
|---|---|
| `response_latency_ms_bucket` federates through | **yes** — 3 series per exposure mode from west |
| `target_port` exists on inbound `response_total` | **yes** — 13 distinct values |
| `namespace` exists on federated proxy series | **yes** — `dr-demo`, `linkerd`, `linkerd-viz`, `linkerd-multicluster`, `dr-observability` |

### The probe filter is not theoretical here

`target_port="4191"` is the **largest single group of inbound series in the
rig** — 143 against 39 for the app's own port 9898. An inbound success-rate SLI
computed without the filter is mostly measuring kubelet probing the proxy. The
article's warning reproduces exactly.

Note the filter is written `target_port!="4191"`, a *negative* matcher, and that
is deliberate rather than stylistic: PromQL treats an absent label as the empty
string, so a negative matcher degrades to matching everything if the label ever
disappears, while the positive form (`target_port="9898"`) would silently select
nothing and blank the panel.

### `classification` and `status_code` genuinely diverge — on gRPC

The dashboard used to plot `classification!="success"` while `verify/lib.sh`
counted anything non-2xx, with nothing reconciling the two. Linkerd's HTTP
classifier marks only 5xx as failure, so a 4xx is a `success` to the metric and
an error to the shell.

That is the documented difference. The one actually observed here is sharper:

```
{namespace="linkerd", status_code="200", target_port="8086"}  classification=failure
```

**A 200 that is a failure.** Port 8086 is control-plane gRPC, and Linkerd
classifies gRPC on `grpc-status`, not the HTTP status — so the two definitions
disagree in the opposite direction from the 4xx case, and a non-2xx filter
misses the failure entirely.

podinfo is HTTP, so on the demo workload the two agree and the *Errors by
exposure mode* panel should show its two series exactly on top of each other. A
visible gap means one of the numbers in the write-up is counting something the
other is not, and the panel says which.

### At steady state the foil is measuring infrastructure

Every inbound non-success series in the rig right now is control plane or viz —
6x `503` on 4191, two `500`s on 9995, the gRPC failure above. **None is
`dr-demo`.** So the foil's `all meshed inbound` series is computed largely over
infrastructure traffic while the demo workload contributes only successes.

That is not a defect in the panel; it is what an unscoped SLO dashboard actually
does, which is the point of having it as a foil. It is the reason the panel
carries a second series scoped to `namespace="dr-demo"` — read them together, or
the foil flatters itself for reasons that have nothing to do with the fault.

## Gateway metrics — previously collected by nothing

Verified live after `clusters/09-grafana.sh` was taught to scrape the
multicluster controllers. Before that change **none of these existed in any
Prometheus in the rig**, which is why the write-up's "gateways available" row
had no query behind it and the gateway-probe experiment was unmeasurable.

Two independent reasons they were missing, and both had to be fixed:

1. `linkerd-viz` does not scrape the `linkerd-multicluster` namespace at all.
2. The controllers' admin port sits behind a default-deny `controller` Server.
   Probing it directly returns **403**, not a connection error — so it looks
   like a broken endpoint rather than a policy decision.

| Metric | Meaning |
|---|---|
| `gateway_alive` | 1 if the mirror controller's probe to that gateway succeeds |
| `gateway_enabled` | 1 if the link *has* a gateway at all |
| `gateway_probes` | probe counter, split by `probe_successful` |
| `gateway_probe_latency_ms_bucket` | probe round-trip histogram |
| `gateway_latency` | last observed probe latency |

Labelled by `target_cluster_name`, one series per Link.

### `gateway_alive == 0` is the resting state for a flat link

Measured from west, with three Links:

| Link | `gateway_enabled` | `gateway_alive` |
|---|---|---|
| `east-gw` (gateway mirror) | 1 | **1** |
| `east` (remote discovery) | 0 | 0 |
| `central` (remote discovery) | 0 | 0 |

A pod-to-pod link has no gateway, so its `gateway_alive` is 0 forever. **An
alert on `gateway_alive == 0` alone is permanently red, once per flat link.**
`gateway_enabled` is the discriminator, and the rule in
`grafana/alert-rules.yml` is gated on it.

Baseline probe latency here is **1.7ms**, which is what makes the 250ms alert
threshold meaningful rather than arbitrary.

### Where the controller runs decides what you can scrape

A service mirror controller runs in the cluster that **links to** a target, not
in the target. `west` links to `east-gw`, so the controller probing that gateway
lives in `west` — the same cluster as the federating Prometheus. That is why
this needed no cross-cluster scrape credentials, and it is worth knowing before
designing gateway monitoring for a real topology: the probe result is owned by
the *client* cluster.

## Also available, not currently used

- `outbound_http_route_request_statuses` / `outbound_http_route_backend_response_statuses`
  — the newer route-oriented metrics. Better structured than `response_total`
  but carry fewer destination labels, so `response_total` remains the better fit
  for cross-cluster attribution.
- `outbound_http_balancer_queue_*` — queue depth and gate state. Potentially
  interesting for showing back-pressure during the FM3 brownout.
- `control_destination_balancer_endpoints` — the proxy's connection to the
  destination controller. Relevant to FM1a: watch what happens to discovery when
  `linkerd-destination` goes away.
