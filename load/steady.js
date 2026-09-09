// Steady-state load against all three cross-cluster exposure modes.
//
// Used for baseline capture and for FM2/FM3/FM4, where we want a constant
// request rate so that any change in success rate or distribution is caused by
// the injected fault and not by us changing the load at the same time.
//
// Note the targets: one per exposure mode, driven concurrently, so a single
// fault produces three directly comparable outcomes in one run.
//
// Client-side numbers here are a sanity check only. The authoritative
// measurements come from this pod's own Linkerd proxy metrics -- the proxy
// carries target_zone / target_cluster / tls labels that k6 cannot see.

import http from 'k6/http';
import { Counter } from 'k6/metrics';

const NS = __ENV.APP_NS || 'dr-demo';
const RPS = parseInt(__ENV.RPS || '30', 10);
const DURATION = __ENV.DURATION || '30m';

// Request timeout, in seconds, in one place. It sets both the per-request
// timeout and the VU pool size, and those two must agree: a VU is held for the
// whole timeout when a request hangs, so sizing the pool without reference to
// this number is how the generator quietly stopped offering the configured rate
// during the exact failures being measured.
const TIMEOUT_S = parseInt(__ENV.TIMEOUT_S || '10', 10);

// Targets are per-cluster, because mirrored services only exist in the clusters
// that link to them. `app-flat-east` exists in west and central but NOT in east --
// east has app-flat-west and app-flat-central instead -- and the gateway mirror
// `app-gateway-east-gw` exists only in west, which is the one cluster with a
// gateway link.
//
// Hardcoding one target list for every cluster means each generator quietly
// hammers services that do not exist in its own cluster, which pollutes the
// error counts and would make FM3 (observed from east) unreadable.
// clusters/08-load.sh supplies the right names per cluster.
const TARGETS = [
  { name: 'federated', url: `http://${__ENV.FEDERATED_SVC || 'app-federated'}.${NS}.svc.cluster.local:9898/api/info` },
];

if (__ENV.FLAT_SVC) {
  TARGETS.push({ name: 'flat_mirror', url: `http://${__ENV.FLAT_SVC}.${NS}.svc.cluster.local:9898/api/info` });
}
if (__ENV.GATEWAY_SVC) {
  TARGETS.push({ name: 'gateway_mirror', url: `http://${__ENV.GATEWAY_SVC}.${NS}.svc.cluster.local:9898/api/info` });
}

const errors = new Counter('dr_errors');
const requests = new Counter('dr_requests');

export const options = {
  scenarios: Object.fromEntries(
    TARGETS.map((t) => [
      t.name,
      {
        executor: 'constant-arrival-rate',
        rate: RPS,
        timeUnit: '1s',
        duration: DURATION,
        preAllocatedVUs: Math.max(10, RPS),
        // Sized off the TIMEOUT, not off RPS alone.
        //
        // constant-arrival-rate needs a VU per in-flight request. When a
        // request hangs it holds its VU for the full timeout, so sustaining
        // RPS with everything hanging needs RPS * TIMEOUT_S VUs -- 300 here.
        // The old cap of RPS*4 = 120 meant k6 starved for VUs during exactly
        // the failures this repo exists to measure, silently dropped
        // iterations, and never actually offered the 30 rps that every
        // "% of expected" figure is computed against. 1.5x headroom over the
        // worst case.
        maxVUs: Math.max(100, Math.ceil(RPS * TIMEOUT_S * 1.5)),
        exec: t.name,
      },
    ])
  ),
  // No thresholds that abort the run: during a DR experiment failures are the
  // point. Aborting would destroy the very measurement we are taking.
  thresholds: {},
};

function hit(target) {
  const res = http.get(target.url, {
    timeout: `${TIMEOUT_S}s`,
    tags: { dr_target: target.name },
  });
  requests.add(1, { dr_target: target.name });
  if (res.status !== 200) {
    errors.add(1, { dr_target: target.name, status: String(res.status) });
  }
}

const byName = (n) => TARGETS.find((t) => t.name === n);

export function federated() { hit(byName('federated')); }
export function flat_mirror() { hit(byName('flat_mirror')); }
export function gateway_mirror() { hit(byName('gateway_mirror')); }
