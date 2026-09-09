#!/usr/bin/env bash
# Build the publishable replay site.
#
#   viz/build.sh [outdir]        default: docs/
#
# Produces a static directory GitHub Pages can serve directly: the page, one
# NDJSON feed per recorded experiment, and a manifest the page turns into a
# run selector.
#
# WHY THE FEEDS ARE COMMITTED
#
# They are generated artifacts, and this repo otherwise keeps generated things
# out of git -- results/* is ignored precisely so run output does not accumulate
# in history. Two reasons this is the exception rather than a lapse:
#
#   1. The raw snapshots are gitignored, so nothing in CI could rebuild these.
#
#   2. A replay's window lengths come from the snapshot files' mtimes, which is
#      the real wall-clock spacing of the run and the only record of it -- the
#      .metrics files carry no timestamps. git does not preserve mtime, so the
#      timing information exists on exactly one machine until this feed is
#      written. Committing the feed preserves it; committing the raw snapshots
#      would not.
#
# So the feed is closer to a measurement than to a build product, and it belongs
# in the repo for the same reason FINDINGS.md does.

. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

OUT="${1:-${REPO_ROOT}/docs}"
VIZ="${REPO_ROOT}/viz"

# Human labels for the run directories. Falls back to the directory name, so a
# new experiment publishes without needing an entry here first.
label_for() {
  case "$1" in
    fm1-destination) echo "FM1 · control plane — destination controller" ;;
    fm1-identity)    echo "FM1 · control plane — identity" ;;
    fm2-graceful)    echo "FM2 · cluster loss — graceful" ;;
    fm2-hard)        echo "FM2 · cluster loss — hard partition" ;;
    fm3)             echo "FM3 · zone brownout" ;;
    fm4)             echo "FM4 · region loss" ;;
    *)               echo "$1" ;;
  esac
}

mkdir -p "${OUT}/feeds"
cp "${VIZ}/index.html" "${OUT}/index.html"

# Pages runs Jekyll by default, which strips paths beginning with an underscore.
# Nothing here starts with one; this is insurance against a future feed that does.
: > "${OUT}/.nojekyll"

entries=""
published=0
skipped=0

# results/<profile>/<run>/ -- two levels since the arms are namespaced. The
# baseline.metrics filter below still does the real work, so the run-<date>
# summary directories at depth 1 drop out on their own.
for dir in "${REPO_ROOT}"/results/*/*/; do
  [ -d "$dir" ] || continue
  run="$(basename "$dir")"
  [ -f "${dir}/baseline.metrics" ] || continue

  # The feed name carries the profile, or namespacing the results directory
  # would just move the collision one level up: results/default/fm3 and
  # results/production/fm3 both basename to "fm3" and would overwrite each
  # other's feed. That is the same defect this change exists to fix, and the
  # two arms have no overlapping experiments YET only by accident.
  dir_profile="$(basename "$(dirname "$dir")")"
  run_id="${dir_profile}-${run}"

  feed="${OUT}/feeds/${run_id}.ndjson"

  # Runs whose provenance was never recorded are SKIPPED rather than guessed.
  #
  # Which cluster a run was observed from is not derivable from its snapshots,
  # and picking wrong is silent: mirror service names differ per cluster, so the
  # wrong observer measures a service that was never exercised and publishes it
  # as zero traffic -- indistinguishable from a mode that died. Publishing that
  # would be worse than publishing nothing.
  if ! bash "${VIZ}/export.sh" replay "$dir" > "$feed" 2>/dev/null; then
    rm -f "$feed"
    warn "skipping '${run}': no observer file, so which cluster it was recorded
       from is unknown. Re-run the experiment to record it, or publish this one
       deliberately with:  OBSERVER=<cluster> viz/build.sh"
    skipped=$((skipped + 1))
    continue
  fi

  n="$(grep -c . "$feed" || true)"
  observer="$(head -1 "$feed" | sed -n 's/.*"observer":"\([^"]*\)".*/\1/p')"

  # Flavor comes from the RUN, not from the shell doing the build.
  #
  # This was $LINKERD_FLAVOR, which is the flavor of whoever happens to be
  # running viz:build -- so `task viz:build` after a BEL run, in a shell that
  # had not exported it, published seven BEL runs labelled "oss". That is not a
  # cosmetic mislabel: endpoints{ready} means the whole pool on OSS and HAZL's
  # active subset on BEL, so the label decides how every endpoint number on the
  # page should be read.
  #
  # Same failure the `observer` file already exists to prevent, and the same
  # fix: read it from the run's own directory, per run, and say so when it is
  # missing rather than guessing.
  # The profile decides how a recovery result should be read: on `default` an
  # unmeshed recovery is the expected outcome, on `production` it is a
  # regression. A replay without it is misread in a specific, confident, wrong
  # direction -- the same failure as publishing seven BEL runs labelled OSS.
  run_profile="$(cat "${dir}/profile" 2>/dev/null || true)"
  if [ -z "$run_profile" ]; then
    run_profile="unknown"
    warn "  ${run}: no profile recorded -- published as \"unknown\" rather than guessed"
  fi

  run_flavor="$(cat "${dir}/flavor" 2>/dev/null || true)"
  if [ -z "$run_flavor" ]; then
    run_flavor="unknown"
    warn "  ${run}: no flavor recorded -- published as \"unknown\" rather than guessed"
  fi

  entries="${entries}$(printf '{"file":"feeds/%s.ndjson","run":"%s","label":"%s","observer":"%s","flavor":"%s","profile":"%s","samples":%s}' \
    "$run_id" "$run_id" "$(label_for "$run")" "$observer" "$run_flavor" "$run_profile" "$n"),"
  ok "${run_id}  ${n} keyframes, observed from ${observer} (${run_flavor}, ${run_profile})"
  published=$((published + 1))
done

[ "$published" -gt 0 ] || die "nothing to publish. Run an experiment first."

# No top-level flavor: it is a per-run property, and a single value at the top
# is wrong the moment the site publishes an OSS run beside a BEL one -- which is
# exactly the comparison this rig exists to make.
printf '{"generated":"%s","feeds":[%s]}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${entries%,}" \
  > "${OUT}/feeds/index.json"

log "built ${OUT}  (${published} published, ${skipped} skipped)"
log "preview with: task viz:site"
