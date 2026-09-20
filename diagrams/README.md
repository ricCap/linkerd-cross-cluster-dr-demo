# Diagrams

Excalidraw scenes, and the editable source of truth for the figures in
[`README.md`](../README.md). Open one at [excalidraw.com](https://excalidraw.com)
or in the VS Code extension, edit, save back over the `.excalidraw`, then
**re-render**:

```bash
python3 diagrams/render-svg.py
```

GitHub will not render an `.excalidraw`, so the committed `.svg` beside each
scene is what a reader actually sees. `render-svg.py` is not Excalidraw's own
exporter: it places every shape exactly, but draws `roughness: 1` shapes as
clean geometry rather than with the hand-drawn wobble. If that matters for a
particular figure, export it from Excalidraw and overwrite the `.svg` — the
README references the file, not the script.

| | |
|---|---|
| `01-steady-state-topology` | three clusters, two regions, zones and the links between them |
| `02-steady-state-exposure-modes` | the same workload exposed three ways, one panel each |
| `03-fm1-control-plane` | FM1, `central`'s control plane scaled to zero |
| `04-fm2-cluster` | FM2, `east` stopped or cut off |
| `05-fm3-zone-brownout` | FM3, one zone of `region-a` slowed |
| `06-fm4-region` | FM4, `region-a` lost |

## The layout

Zones are vertical columns. A cluster is a horizontal band crossing them, and
each cluster × zone cell holds a node. Two clusters in one region cross the
*same* three columns, which is the point: `east` and `central` share
`zone-a1..a3`. An earlier layout drew those zones once per cluster and so
implied six distinct zones where there are three.

| | |
|---|---|
| dashed grey box | a region |
| grey column | a zone |
| black band | a cluster |
| node icon, podinfo card | one node, one app replica |
| dimmed + red X | the cluster is gone (FM2, FM4) |
| red cell outline | that zone is slowed, not gone (FM3) |
| teal, double-headed | flat pod-to-pod link — every ordered pair, both ways |
| amber dashed, single head | gateway link — one way, into `east` |

Ordering follows [`CHARTS.md`](../CHARTS.md): west, then central above east.

## Checked against the topology

Verified against `clusters/lib.sh` after the region-scoped zone rework: zone
names (`zone-b1..b3` in west, `zone-a1..a3` shared by east and central), the pod
CIDRs, `dr-net 172.28.0.0/16`, the 9-endpoint federated pool, the exposure
labels, each experiment's target, and which cluster each is observed from. FM3
slows `zone-a1` in region-a and leaves west alone, which is what the brownout
does. Link directions come from `clusters/05-multicluster.sh`.
