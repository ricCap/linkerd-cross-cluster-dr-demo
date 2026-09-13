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

Ordering follows [`CHARTS.md`](../CHARTS.md): clusters read **west → central →
east**, with the region boundaries drawn around them. `07` lists FM4's target as
`central + east` for the same reason.
