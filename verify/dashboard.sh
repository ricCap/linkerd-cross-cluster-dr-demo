#!/usr/bin/env bash
# Prove every panel on the DR dashboard actually returns data, BEFORE a run.
#
#   verify/dashboard.sh              check as observed from west
#   OBSERVER=east verify/dashboard.sh
#
# An empty Grafana panel is the most expensive failure in this repo. It does not
# error, it does not warn, and it looks exactly like "the experiment produced
# nothing" -- which is indistinguishable from a real negative result until you
# go and re-read the query. Two of those have already cost a run here: a metric
# that does not exist in the OSS proxy, and a label that only exists on gateway
# mirrors. Both were found after the fault had been injected and restored.
#
# So: extract every expr from grafana/dr-dashboard.json, run it against the
# federating Prometheus, and report which ones come back with series. Cheap to
# run, and it is the difference between a failed panel and a failed experiment.
#
# Exits non-zero if any query that SHOULD have data does not.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../clusters/lib.sh"

need kubectl python3

GRAFANA_NS="${GRAFANA_NS:-dr-observability}"
HOST_CLUSTER="${HOST_CLUSTER:-west}"
OBSERVER="${OBSERVER:-$HOST_CLUSTER}"
DASHBOARD="${REPO_ROOT}/grafana/dr-dashboard.json"
CTX="$(ctx "$HOST_CLUSTER")"

# BEL-only series. On OSS these are legitimately absent, so an empty result is
# the expected answer rather than a failure -- see verify/metrics.md.
BEL_ONLY='outbound_http_balancer_adaptive_'

banner() { printf '\n\033[1m%s\033[0m\n\n' "$*"; }

# All queries go through the Grafana pod, the same trick verify/annotate.sh
# uses: it has wget, it can reach the Prometheus service, and it means this
# works with no port-forward and no assumptions about the host's network.
# Wait for the rollout FIRST. Immediately after a redeploy both the old and new
# pods exist, and taking items[0] picks whichever the API lists first -- often
# the one that is terminating. Then select a pod that is actually Ready, rather
# than the first one with the right label.
kubectl --context="$CTX" -n "$GRAFANA_NS" rollout status deploy/grafana \
  --timeout=180s >/dev/null 2>&1 || true

POD="$(kubectl --context="$CTX" -n "$GRAFANA_NS" get pod -l app=grafana \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
  | awk '$2 == "True" { print $1; exit }')"
[ -n "$POD" ] || die "no Ready Grafana pod in ${GRAFANA_NS} on ${HOST_CLUSTER}.
     Run 'task up', or wait for a redeploy to finish."

PROM="http://dr-prometheus.${GRAFANA_NS}.svc.cluster.local:9090"

# Emits one TAB-separated record per target: title, refId, kind, the URL-encoded
# expression with $observer resolved, and a probe expression (or "-").
#
# The probe exists because "no series" is the CORRECT answer for an error panel
# on a healthy rig -- nothing is failing, so nothing matches. Skipping those
# outright would blind the gate to the failure it is most likely to catch: a
# mistyped authority regex, which also returns nothing. So for an error panel we
# strip the error predicate and re-ask. If the rest of the selector matches, the
# panel is wired correctly and merely quiet; if it does not, the selector is
# broken and the panel would have stayed blank through the fault too.
targets_tsv() {
  python3 - "$DASHBOARD" "$OBSERVER" "$BEL_ONLY" <<'PY'
import json, sys, urllib.parse
dash, observer, bel = sys.argv[1], sys.argv[2], sys.argv[3]

# Predicates that select only failing requests, with their trailing separator.
ERROR_PREDICATES = ['classification!="success", ', 'status_code!~"2..", ']

def enc(e):
    return urllib.parse.quote(e, safe="")

for p in json.load(open(dash)).get("panels", []):
    for t in p.get("targets", []):
        expr = t.get("expr")
        if not expr:
            continue
        # A BEL-only expr with an `or` fallback still resolves on OSS.
        bel_only = bel in expr and " or " not in expr
        resolved = expr.replace("$observer", observer)

        probe = "-"
        stripped = resolved
        for pred in ERROR_PREDICATES:
            stripped = stripped.replace(pred, "")
        if stripped != resolved:
            probe = enc(stripped)

        if bel_only:
            kind = "bel"
        elif "ALERTS" in resolved:
            # Empty is the healthy state: Prometheus emits ALERTS only while a
            # rule is pending or firing. Whether the rules LOADED is checked
            # separately and explicitly, which is the failure this would
            # otherwise be confused with.
            kind = "alerts"
        elif probe != "-":
            kind = "err"
        else:
            kind = "-"
        print("\t".join([
            p.get("title") or "(text)", t.get("refId", "?"),
            kind, enc(resolved), probe,
        ]))
PY
}

# Series count for one encoded expression, or "ERR:<reason>".
series_count() {
  local encoded="$1" body
  body="$(kubectl --context="$CTX" -n "$GRAFANA_NS" exec "$POD" -- \
    wget -qO- "${PROM}/api/v1/query?query=${encoded}" 2>/dev/null || true)"
  [ -n "$body" ] || { echo "ERR:no response"; return; }
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR:unparseable"); raise SystemExit
if d.get("status") != "success":
    print("ERR:" + str(d.get("error", "query failed"))[:60]); raise SystemExit
print(len(d.get("data", {}).get("result", [])))
'
}

# Federation has to have scraped at least twice before any rate() can resolve,
# and `task up` calls this straight after deploying Grafana. Without the wait
# every query reports EMPTY on a perfectly healthy rig, which trains people to
# ignore exactly the signal this script exists to give.
# "response_total" needs no URL escaping, so it can be passed through as-is.
have_traffic() {
  local n
  n="$(series_count response_total)"
  case "$n" in ERR:*|0) return 1 ;; *) return 0 ;; esac
}
log "waiting for federated proxy metrics to appear"
retry 18 5 have_traffic \
  || die "no response_total in the federating Prometheus after 90s.
     Either the load generators are not running (task load) or federation is
     broken -- check the targets page on dr-prometheus."

fails=0; skipped=0; checked=0; query_fails=0

banner "dashboard readiness -- ${OBSERVER} as observer, flavor ${LINKERD_FLAVOR}"

# The template variable, first. If it fails to populate, Grafana resolves
# $observer to the empty string and cluster=~"" matches only series with NO
# cluster label -- so every scoped panel goes blank at once, with no error
# anywhere. That looks exactly like a dead rig. The script substitutes the
# observer itself below, so nothing further would catch it.
printf '\033[1;36m%s\033[0m\n' 'template variable: observer'
var_values="$(kubectl --context="$CTX" -n "$GRAFANA_NS" exec "$POD" -- \
  wget -qO- "${PROM}/api/v1/label/cluster/values?match%5B%5D=response_total" 2>/dev/null \
  | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("data", [])))' 2>/dev/null || true)"

if [ -z "$var_values" ]; then
  printf '  \033[1;31mEMPTY\033[0m  no cluster label values -- every scoped panel will be blank\n'
  fails=$((fails + 1))
elif ! echo " $var_values " | grep -q " ${OBSERVER} "; then
  printf '  \033[1;31mFAIL\033[0m   observer %s not among: %s\n' "$OBSERVER" "$var_values"
  fails=$((fails + 1))
else
  printf '  \033[1;32mok\033[0m     %s\n' "$var_values"
fi

last_title=""

while IFS=$'\t' read -r title refid kind encoded probe; do
  [ -n "${encoded:-}" ] || continue
  if [ "$title" != "$last_title" ]; then
    printf '\033[1;36m%s\033[0m\n' "$title"
    last_title="$title"
  fi

  n="$(series_count "$encoded")"
  checked=$((checked + 1))

  case "$n" in
    ERR:*)
      printf '  %-4s \033[1;31mERROR\033[0m  %s\n' "$refid" "${n#ERR:}"
      fails=$((fails + 1)); query_fails=$((query_fails + 1))
      ;;
    0)
      if [ "$kind" = "bel" ] && [ "$LINKERD_FLAVOR" != "bel" ]; then
        printf '  %-4s \033[2mskip\033[0m   BEL-only series, absent on OSS as expected\n' "$refid"
        skipped=$((skipped + 1))
      elif [ "$kind" = "alerts" ]; then
        printf '  %-4s \033[2mskip\033[0m   no alert firing right now; rules checked separately below\n' "$refid"
        skipped=$((skipped + 1))
      elif [ "$kind" = "err" ] && [ "$probe" != "-" ]; then
        # Empty is right when nothing is failing -- but only if the rest of the
        # selector still matches something.
        pn="$(series_count "$probe")"
        case "$pn" in
          ERR:*|0)
            printf '  %-4s \033[1;31mEMPTY\033[0m  selector matches nothing even without the error filter\n' "$refid"
            fails=$((fails + 1)); query_fails=$((query_fails + 1))
            ;;
          *)
            printf '  %-4s \033[1;32mok\033[0m     no errors right now; selector matches %s series\n' "$refid" "$pn"
            skipped=$((skipped + 1))
            ;;
        esac
      else
        printf '  %-4s \033[1;31mEMPTY\033[0m  no series -- this panel will render blank\n' "$refid"
        fails=$((fails + 1)); query_fails=$((query_fails + 1))
      fi
      ;;
    *)
      printf '  %-4s \033[1;32mok\033[0m     %s series\n' "$refid" "$n"
      ;;
  esac
done < <(targets_tsv)

printf '\n%s queries checked, %s legitimately empty (BEL-only, or no errors to show)\n' "$checked" "$skipped"

# --- alerting rules ---------------------------------------------------------
#
# A malformed rule file is SILENTLY IGNORED by Prometheus: it logs, starts
# anyway, and serves an empty rule list. Nothing downstream complains, and the
# first symptom is an experiment that recorded no alerts -- which reads exactly
# like "the alerts correctly stayed quiet", the result we are trying to claim.
banner "alerting rules"

rules_json="$(kubectl --context="$CTX" -n "$GRAFANA_NS" exec "$POD" -- \
  wget -qO- "http://localhost:3000/api/prometheus/dr-prom/api/v1/rules" 2>/dev/null || true)"

rules_summary="$(printf '%s' "$rules_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR unparseable"); raise SystemExit
groups = d.get("data", {}).get("groups", [])
rec = sum(1 for g in groups for r in g["rules"] if r.get("type") == "recording")
al  = [r for g in groups for r in g["rules"] if r.get("type") == "alerting"]
firing = [r["name"] for r in al if r.get("state") == "firing"]
print("OK", len(groups), rec, len(al), ",".join(firing) or "-")
' 2>/dev/null || echo "ERR query failed")"

set -- $rules_summary
if [ "$1" != "OK" ] || [ "${2:-0}" -eq 0 ]; then
  printf '  \033[1;31mFAIL\033[0m   no rule groups loaded -- Prometheus ignored the rule file\n'
  printf '         validate it with: docker run --rm -v "$PWD/grafana:/r:ro" \\\n'
  printf '           --entrypoint promtool prom/prometheus:v3.1.0 check rules /r/alert-rules.yml\n'
  fails=$((fails + 1))
else
  printf '  \033[1;32mok\033[0m     %s groups, %s recording rules, %s alerts loaded\n' "$2" "$3" "$4"
  if [ "${5:-}" != "-" ]; then
    printf '  \033[1;33mnote\033[0m   already firing before injection: %s\n' "$5"
  fi
fi

# --- baseline warm-up -------------------------------------------------------
#
# MeshThroughputCollapse compares a 1m rate against a 15m baseline, and the foil
# rules use a 1h window. For the first 15 minutes after Prometheus restarts, the
# 15m window is only partly populated and the baseline reads LOW -- measured at
# 3.33 against a 1m rate of 24.98 right after a redeploy, a 7.5x understatement.
# That biases the ratio upward, which is the dangerous direction: it MASKS a
# real collapse rather than inventing one. Injecting a fault into a cold
# Prometheus produces a quiet alert timeline that looks like a finding.
warm="$(series_count "$(python3 -c '
import urllib.parse
print(urllib.parse.quote("min(mesh:mode_throughput:rate15m / clamp_min(mesh:mode_throughput:rate1m, 0.001)) > 0.7", safe=""))
')")"
case "$warm" in
  ERR:*|0)
    printf '  \033[1;31mFAIL\033[0m   15m baseline has not filled -- alerts using it will under-fire\n'
    printf '         Prometheus restarted recently. Wait 15 minutes (60 for the 1h foil\n'
    printf '         rules) before injecting, or the quiet timeline is an artifact.\n'
    fails=$((fails + 1))
    ;;
  *)
    printf '  \033[1;32mok\033[0m     15m baseline is warm\n'
    ;;
esac

if [ "$query_fails" -gt 0 ]; then
  printf '\n\033[1;33m%s panel quer%s returned nothing.\033[0m An empty panel after the fact is\n' \
    "$query_fails" "$([ "$query_fails" -eq 1 ] && echo y || echo ies)"
  printf 'indistinguishable from a null result. Usual causes: a label absent on this\n'
  printf 'flavor (verify/metrics.md), a metric that never federated (09-grafana.sh\n'
  printf 'match[]), or a service name that differs for this observer (modes_for).\n'
fi

[ "$fails" -eq 0 ] || die "not ready -- ${fails} check(s) failed above."

ok "dashboard is ready: every panel has data, rules are loaded, baselines are warm"
