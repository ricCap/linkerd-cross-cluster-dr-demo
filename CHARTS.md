# Chart and diagram conventions

Anything that shows clusters, regions or zones — a Grafana panel, the status
page, a hand-drawn figure in the write-up — orders them the same way. A reader
who has learned to find `east` in one picture should not have to re-learn it in
the next, and an ordering that changes between figures reads as a difference in
the data rather than a difference in the drawing.

The orderings below are fixed **at the source**, not at the drawing.
`CLUSTER_TABLE` in `clusters/lib.sh` is the declaration; `clusters()`,
`regions()` and `all_zones()` return them in order, and anything that renders
reads those rather than sorting for itself.

## Clusters read west → central → east

Order clusters the way a reader would say them out loud. The names are
geographic, so the sequence is geographic: **west, central, east** reads as a
line across a map. `west, east, central` is the same three clusters in an order
that makes the reader stop and check each label, and check again in the next
figure.

Left to right on a horizontal axis; top to bottom on a vertical one. Same
sequence in a legend, a table, a list of targets in prose — `east + central` is
written `central + east`.

`west` is deliberately the first row of `CLUSTER_TABLE`, and the convention
keeps it first. It is the observer no experiment may touch, so it is also the
cluster a reader refers back to most.

## Regions are ordered alphabetically

There is no meaningful sequence between `region-a` and `region-b` — they are
labels, not places — so the tie is broken by name, and broken the same way
everywhere. `regions()` sorts rather than returning declaration order for
exactly this reason: declaration order cannot produce it, because `west` is
deliberately declared first and `west` is the sole cluster in `region-b`.

## When the two collide, the cluster sequence wins

This topology makes them collide. `region-a` holds **central** and **east**;
`region-b` holds **west** alone. Ordering the regions alphabetically across a
figure would put `west` on the far right and make the clusters read
`central → east → west`.

So: **lay the clusters out first, and draw the region boundaries around them.**
Region boxes then fall `region-b`, `region-a`, and that is correct, because the
alphabetical rule governs regions *as a list* — a legend, a table, a region
axis, `regions()` — and not the position of a box drawn around clusters that
have already been placed.

The region boxes stay contiguous either way, because `west` is at one end.

```
[ region-b ]   [ region-a           ]
[  west    ]   [ central  |  east   ]

west → central → east
```

## Zones follow their region

`zone-a1 … a3` in `region-a`, `zone-b1 … b3` in `region-b`, ascending. Zone
names are region-scoped and not interchangeable: a bare `zone-b` is west's
`zone-b2` or east's `zone-a2` depending on whose node it was. See
`results/SHORTCOMINGS.md` § 16.

## Colour and line style carry meaning, so keep them stable

In the figures, teal solid is a **pod-to-pod (flat) link** and amber dashed is a
**gateway link**. Reordering a figure must preserve which pairs of clusters each
connector joins, and how many there are — `west` has *two* links to `east`, and
a redraw that quietly moves one of them to `central` changes what the picture
claims. `GATEWAY_LINKS` in `clusters/05-multicluster.sh` is the authority.

## Recorded runs are exempt

`results/` and `docs/feeds/` are the record of what was measured, in the
vocabulary and order of the run that produced them. They are re-measured, never
re-ordered. The published status page reads names out of each feed rather than
from the code, so it follows the run and not this file.

---

Applies to `grafana/dr-dashboard.json`, `viz/`, and `diagrams/`.
