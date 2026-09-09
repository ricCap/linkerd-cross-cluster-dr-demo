// Staged RPS ramp against the federated service, used to walk HAZL's load band.
//
// HAZL defines load as latency x throughput for a single endpoint. It adds
// non-local-zone endpoints when that value crosses BUOYANT_BALANCER_LOAD_HIGH
// (default 2.0) and withdraws them when it falls below
// BUOYANT_BALANCER_LOAD_LOW (default 0.8).
//
// Both terms matter, which is why FM1 has two variants:
//   - this ramp raises THROUGHPUT
//   - chaos/fm1-zone-brownout.yaml raises LATENCY
// Run the ramp alone to find the RPS at which the band is crossed on a healthy
// cluster; run it with the brownout to show the band being crossed at a much
// lower RPS because latency is elevated.
//
// The hold stages are deliberately long. HAZL is measuring a moving average, so
// a fast ramp reaches high RPS before the balancer has reacted, and you cannot
// tell which RPS actually triggered the expansion.

import http from 'k6/http';

const NS = __ENV.APP_NS || 'dr-demo';
const TARGET = __ENV.TARGET || `http://app-federated.${NS}.svc.cluster.local:9898/api/info`;

const LOW = parseInt(__ENV.RPS_LOW || '20', 10);
const MID = parseInt(__ENV.RPS_MID || '100', 10);
const HIGH = parseInt(__ENV.RPS_HIGH || '400', 10);
const HOLD = __ENV.HOLD || '3m';

export const options = {
  scenarios: {
    band_walk: {
      executor: 'ramping-arrival-rate',
      startRate: LOW,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 1000,
      stages: [
        // Baseline: expect traffic to stay in-zone.
        { target: LOW, duration: HOLD },
        { target: MID, duration: '1m' },
        { target: MID, duration: HOLD },
        // Expect the band to be crossed somewhere in here.
        { target: HIGH, duration: '1m' },
        { target: HIGH, duration: HOLD },
        // Back down: expect endpoints to be withdrawn again.
        { target: LOW, duration: '1m' },
        { target: LOW, duration: HOLD },
      ],
    },
  },
  thresholds: {},
};

export default function () {
  http.get(TARGET, { timeout: '10s', tags: { dr_target: 'federated' } });
}
