/**
 * Petclinic Load Test — k6 script (PETPLAT-102)
 *
 * Usage:
 *   k6 run scripts/load-tests/petclinic-load-test.js \
 *     -e BASE_URL=https://petclinic.{YOUR_DOMAIN}
 *
 * Thresholds (SLOs from technical-spec.md):
 *   - p95 latency < 500ms
 *   - error rate  < 1%
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// ── Custom metrics ──────────────────────────────────────────────────────────

const errorRate = new Rate('error_rate');
const apiGatewayLatency = new Trend('api_gateway_latency_ms');

// ── Test options ────────────────────────────────────────────────────────────

export const options = {
  stages: [
    { duration: '1m', target: 10 },   // ramp-up to 10 VUs
    { duration: '3m', target: 10 },   // steady load
    { duration: '1m', target: 25 },   // spike to 25 VUs
    { duration: '2m', target: 25 },   // hold spike
    { duration: '1m', target: 0 },    // ramp-down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],  // SLO: p95 < 500ms
    error_rate:        ['rate<0.01'],  // SLO: < 1% errors
    http_req_failed:   ['rate<0.01'],
  },
};

// ── Helpers ─────────────────────────────────────────────────────────────────

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

function get(path, tag) {
  const res = http.get(`${BASE_URL}${path}`, {
    tags: { endpoint: tag },
    timeout: '10s',
  });
  const ok = check(res, {
    [`${tag} status 2xx`]: (r) => r.status >= 200 && r.status < 300,
  });
  errorRate.add(!ok);
  apiGatewayLatency.add(res.timings.duration);
  return res;
}

// ── Scenarios ────────────────────────────────────────────────────────────────

/**
 * Golden path: browse vets, owners, and pets through the API gateway.
 */
export default function () {
  // Vets list — cached by Caffeine in vets-service
  get('/api/vet/vets', 'list-vets');
  sleep(0.5);

  // Owners list
  const ownersRes = get('/api/customer/owners', 'list-owners');
  sleep(0.3);

  // Owner detail + pets (pick first owner if list returned correctly)
  if (ownersRes.status === 200) {
    try {
      const owners = JSON.parse(ownersRes.body);
      if (Array.isArray(owners) && owners.length > 0) {
        const ownerId = owners[0].id;
        get(`/api/customer/owners/${ownerId}`, 'get-owner');
        sleep(0.2);
      }
    } catch (_) {
      // non-JSON or empty — skip
    }
  }

  // Visits for pet 1 (static — avoids tight loop on random IDs)
  get('/api/visit/pets/1/visits', 'list-visits');
  sleep(1);
}

/**
 * Health check scenario — runs a constant 1 VU throughout to verify
 * actuator endpoints remain responsive under load.
 */
export function healthChecks() {
  get('/actuator/health', 'health');
  sleep(5);
}

export const scenarios = {
  load: {
    executor: 'ramping-vus',
    exec: 'default',
    startVUs: 0,
    stages: options.stages,
  },
  health: {
    executor: 'constant-vus',
    exec: 'healthChecks',
    vus: 1,
    duration: '8m',
  },
};
