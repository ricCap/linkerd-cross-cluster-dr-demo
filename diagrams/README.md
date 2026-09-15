# Diagrams

Excalidraw scenes, and the editable source of truth for the diagrams in the
write-up. Open them at [excalidraw.com](https://excalidraw.com) or in the VS Code
extension, edit, and save back over the `.excalidraw` file.

They came from the private `linkerd-cross-cluster-disaster-recovery-demo` repo,
which is being retired. Only the scenes were carried over — not the SVG/PNG
renders, and not the `render.sh` / `to-excalidraw.py` pipeline that produced
them. Export from Excalidraw when a render is needed.

| | |
|---|---|
| `01-steady-state-topology` | three clusters, two regions, zones and pod CIDRs |
| `02-steady-state-exposure-modes` | the same workload exposed three ways |
| `03-fm1-control-plane` | FM1, `central` frozen |
| `04-fm2-cluster` | FM2, `east` stopped or cut off |
| `05-fm3-zone-brownout` | FM3, one zone of `region-a` slowed |
| `06-fm4-region` | FM4, `region-a` lost |
| `07-mode-coverage` | every exposure mode against every failure mode |
| `all-diagrams` | all seven on one canvas |

## Checked against the topology

Verified against `clusters/lib.sh` after the region-scoped zone rework: zone
names (`zone-b1..b3` in west, `zone-a1..a3` shared by east and central), the
pod CIDRs, `dr-net 172.28.0.0/16`, the 9-endpoint federated pool, the exposure
labels, each experiment's target, and which cluster each is observed from. FM3
slows `zone-a1` in region-a and leaves west alone, which is what the brownout
now does.

`all-diagrams` is **generated**: run `python3 diagrams/build-all.py` after
editing any of the seven, and never edit it by hand. `example.excalidraw` is the style reference and holds the
node icon at its original 684px; the scenes embed a 256px copy, which is eight
times the 32px they draw it at and a tenth of the bytes.

## The layout

Zones are vertical columns. A cluster is a horizontal band crossing them, and
each cluster × zone cell holds one Kubernetes node. Two clusters in one region
cross the *same* three columns, which is the point: `east` and `central` share
`zone-a1..a3`. The previous layout drew those zones once per cluster and so
implied six distinct zones where there are three.

| | |
|---|---|
| dashed grey box | a region |
| grey column | a zone |
| black band | a cluster |
| node icon | one node, one app replica |
| dimmed icon + red X | the cluster is gone (FM2, FM4) |
| red cell outline | that zone is slowed, not gone (FM3) |
| teal solid | flat, pod-to-pod link |
| amber dashed | gateway link |

Ordering follows [`CHARTS.md`](../CHARTS.md): west, then central above east.
