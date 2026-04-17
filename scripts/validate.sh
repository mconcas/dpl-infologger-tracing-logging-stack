#!/usr/bin/env bash
# validate.sh — end-to-end observability pipeline validation.
#
# Verifies every hop in the instrumented-application → observability-backend
# pipeline, from the running containers all the way to correlated services
# in OpenSearch.
#
# Topology (two docker-compose stacks, one shared network):
#
#   o2-stack ──traces──► otel-collector ──► data-prepper ──► OpenSearch
#       │                     ▲                                  ▲
#       └──syslog──► fluent-bit ─────► otel-collector ───────────┘
#                        (logs)            (logs)
#
# Usage:
#   ./scripts/validate.sh            # run all checks
#   ./scripts/validate.sh --quick    # skip the 20 s data-growth check

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
OPENSEARCH_PASSWORD="${OPENSEARCH_PASSWORD:-MyStr0ng!Pass#2024}"
OS_URL="https://localhost:9200"
OS_AUTH="admin:${OPENSEARCH_PASSWORD}"
PROM_URL="http://localhost:9090"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../docker-compose.yml"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

# ── Colours / helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo -e "${YELLOW}▸${NC} $1"; }

os_query() {
  curl -sk -u "$OS_AUTH" "$@" 2>/dev/null
}
os_count() {
  os_query "$OS_URL/$1/_count" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0"
}
os_search() {
  os_query -X POST "$OS_URL/$1/_search" -H 'Content-Type: application/json' -d "$2"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — Containers
# ═════════════════════════════════════════════════════════════════════════════
info "Step 1: Containers"

# App-stack containers
for svc in mariadb infologger-server o2-stack; do
  state=$(docker inspect --format='{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
  [[ "$state" == "true" ]] && pass "$svc running" || fail "$svc not running"
done

# Observability-stack containers
for svc in fluent-bit otel-collector data-prepper opensearch opensearch-dashboards; do
  state=$(docker inspect --format='{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
  [[ "$state" == "true" ]] && pass "$svc running" || fail "$svc not running"
done

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — InfoLogger chain (app → infoLoggerD → server → MariaDB)
# ═════════════════════════════════════════════════════════════════════════════
info "Step 2: InfoLogger → MariaDB"

MSG_COUNT=$(docker compose -f "$COMPOSE_FILE" exec -T mariadb \
  mariadb -h 127.0.0.1 -u infoLoggerAdmin -pilgadmin INFOLOGGER \
  -se "SELECT COUNT(*) FROM messages;" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
[[ "${MSG_COUNT:-0}" -gt 0 ]] \
  && pass "MariaDB has $MSG_COUNT InfoLogger messages" \
  || fail "MariaDB has 0 InfoLogger messages"

# Check traceid/spanid columns exist and some are populated
TRACED_MSGS=$(docker compose -f "$COMPOSE_FILE" exec -T mariadb \
  mariadb -h 127.0.0.1 -u infoLoggerAdmin -pilgadmin INFOLOGGER \
  -se "SELECT COUNT(*) FROM messages WHERE traceid IS NOT NULL AND traceid != '';" 2>/dev/null \
  | tail -1 | tr -d '[:space:]' || echo "0")
[[ "${TRACED_MSGS:-0}" -gt 0 ]] \
  && pass "MariaDB: $TRACED_MSGS messages with traceid" \
  || fail "MariaDB: no messages with traceid (tracing context not propagated to InfoLogger)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Syslog bridge → Fluent-Bit
# ═════════════════════════════════════════════════════════════════════════════
info "Step 3: InfoLogger bridge → Fluent-Bit"

FB_STATUS=$(docker logs fluent-bit 2>&1 | grep -c "HTTP status=200" || echo "0")
[[ "${FB_STATUS:-0}" -gt 0 ]] \
  && pass "Fluent-Bit forwarding to otel-collector ($FB_STATUS successful sends)" \
  || fail "Fluent-Bit has no successful sends to otel-collector"

# Verify the bridge process is running inside infologger-server (no ps/pgrep in minimal image)
BRIDGE_FOUND=$(docker exec infologger-server sh -c \
  'for p in /proc/[0-9]*/cmdline; do
     if cat "$p" 2>/dev/null | tr "\0" " " | grep -q "o2-infologger-bridge"; then echo "yes"; break; fi
   done')
[[ "$BRIDGE_FOUND" == "yes" ]] \
  && pass "InfoLogger bridge running" \
  || fail "InfoLogger bridge not running inside infologger-server"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — OTel Collector health
# ═════════════════════════════════════════════════════════════════════════════
info "Step 4: OTel Collector"

# Check recent errors (last 2 minutes); ignore gRPC connection-refused at startup
OTEL_ERRORS=$(docker logs --since 2m otel-collector 2>&1 | grep -i 'error' | grep -cv 'connection refused' | tr -d '[:space:]')
OTEL_ERRORS=${OTEL_ERRORS:-0}
[[ "$OTEL_ERRORS" -eq 0 ]] \
  && pass "No recent errors in otel-collector logs" \
  || fail "otel-collector has $OTEL_ERRORS recent error lines (excluding startup connection refused)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — Data Prepper → OpenSearch: Traces
# ═════════════════════════════════════════════════════════════════════════════
info "Step 5: Traces in OpenSearch"

SPAN_COUNT=$(os_count "otel-v1-apm-span-000001")
[[ "${SPAN_COUNT:-0}" -gt 0 ]] \
  && pass "Spans indexed: $SPAN_COUNT" \
  || fail "No spans in otel-v1-apm-span-000001"

# Check all 4 services present
SERVICES=$(os_search "otel-v1-apm-span-000001" \
  '{"size":0,"aggs":{"svc":{"terms":{"field":"serviceName","size":20}}}}' \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
buckets=d.get('aggregations',{}).get('svc',{}).get('buckets',[])
names=sorted([b['key'] for b in buckets])
print(' '.join(names))
" 2>/dev/null || echo "")

for expected in A B C D; do
  if echo "$SERVICES" | grep -qw "$expected"; then
    pass "Service '$expected' found in spans"
  else
    fail "Service '$expected' missing from spans (found: $SERVICES)"
  fi
done

# Check traceGroup is set on root spans
ROOT_WITH_TG=$(os_search "otel-v1-apm-span-000001" \
  '{"size":0,"query":{"bool":{"must":[{"term":{"parentSpanId":""}},{"exists":{"field":"traceGroup"}}]}}}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "0")
[[ "${ROOT_WITH_TG:-0}" -gt 0 ]] \
  && pass "Root spans with traceGroup: $ROOT_WITH_TG" \
  || fail "No root spans have traceGroup set (OSD Services page needs this)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — Service Map
# ═════════════════════════════════════════════════════════════════════════════
info "Step 6: Service Map in OpenSearch"

SVCMAP_COUNT=$(os_count "otel-v1-apm-service-map")
[[ "${SVCMAP_COUNT:-0}" -gt 0 ]] \
  && pass "Service map: $SVCMAP_COUNT documents" \
  || fail "Service map is empty"

# OSD Trace Analytics queries the flat serviceName field in the service-map index.
# Data Prepper 2.x writes nested sourceNode/targetNode; the service-map-compat
# ingest pipeline must populate flat serviceName for the Application Map to work.
SVCMAP_SERVICES=$(os_search "otel-v1-apm-service-map" \
  '{"size":0,"aggs":{"recent":{"filter":{"range":{"timestamp":{"gte":"now-1h||-365d"}}},"aggs":{"svc":{"terms":{"field":"serviceName","size":10}}}}}}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
buckets = d.get('aggregations',{}).get('recent',{}).get('svc',{}).get('buckets',[])
print(len(buckets))
" 2>/dev/null || echo "0")
# Fallback: if the time-range agg returned 0, just check top-N most recent docs
if [[ "${SVCMAP_SERVICES:-0}" -eq 0 ]]; then
  SVCMAP_SERVICES=$(os_search "otel-v1-apm-service-map" \
    '{"size":5,"sort":[{"timestamp":"desc"}],"_source":["serviceName"]}' \
    | python3 -c "
import sys, json
hits = json.load(sys.stdin).get('hits',{}).get('hits',[])
print(sum(1 for h in hits if h.get('_source',{}).get('serviceName')))
" 2>/dev/null || echo "0")
fi
[[ "${SVCMAP_SERVICES:-0}" -gt 0 ]] \
  && pass "Application Map: serviceName present in recent service-map docs" \
  || fail "No service-map docs with serviceName (ingest pipeline service-map-compat missing?)"

# Simulate the OSD Trace Analytics DSL query through the OSD API
OSD_SVCMAP=$(curl -sk -u "$OS_AUTH" -X POST \
  "http://${OSD_HOST:-localhost}:5601/api/observability/trace_analytics/query" \
  -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"index":"otel-v1-apm-service-map*","size":0,"query":{"bool":{"must":[],"filter":[],"should":[],"must_not":[]}},"aggs":{"service_name":{"terms":{"field":"serviceName","size":200}}}}' 2>/dev/null \
  | python3 -c "import sys,json; buckets=json.load(sys.stdin).get('aggregations',{}).get('service_name',{}).get('buckets',[]); print(len(buckets))" 2>/dev/null || echo "0")
[[ "${OSD_SVCMAP:-0}" -gt 0 ]] \
  && pass "OSD Application Map API: $OSD_SVCMAP services returned" \
  || fail "OSD Application Map API returns no services (check OSD settings/connectivity)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 — Logs in OpenSearch
# ═════════════════════════════════════════════════════════════════════════════
info "Step 7: Logs in OpenSearch"

LOG_COUNT=$(os_count "logs-otel-v1-000001")
[[ "${LOG_COUNT:-0}" -gt 0 ]] \
  && pass "Logs indexed: $LOG_COUNT" \
  || fail "No logs in logs-otel-v1-000001"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 — Log ↔ Trace correlation (traceId in logs)
# ═════════════════════════════════════════════════════════════════════════════
info "Step 8: Log-trace correlation"

CORR_LOGS=$(os_search "logs-otel-v1-000001" \
  '{"size":0,"query":{"bool":{"must_not":[{"term":{"traceId":""}}],"must":[{"exists":{"field":"traceId"}}]}}}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "0")
[[ "${CORR_LOGS:-0}" -gt 0 ]] \
  && pass "Logs with traceId: $CORR_LOGS" \
  || fail "No logs have traceId set (trace-log correlation broken)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 9 — Log ↔ Service correlation (serviceName in logs)
# ═════════════════════════════════════════════════════════════════════════════
info "Step 9: Log-service correlation"

# The schemaMappings say serviceName lives at resource.attributes.service.name
LOGS_WITH_SVC=$(os_search "logs-otel-v1-000001" \
  '{"size":0,"query":{"bool":{"must":[{"exists":{"field":"resource.attributes.service.name"}}]}}}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "0")
[[ "${LOGS_WITH_SVC:-0}" -gt 0 ]] \
  && pass "Logs with service.name: $LOGS_WITH_SVC" \
  || fail "No logs have resource.attributes.service.name (logs won't be associated to services in OSD)"

# Also check the flat serviceName field that data-prepper might set
LOGS_WITH_SVCNAME=$(os_search "logs-otel-v1-000001" \
  '{"size":0,"query":{"bool":{"must":[{"exists":{"field":"serviceName"}}]}}}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "0")
if [[ "${LOGS_WITH_SVC:-0}" -eq 0 ]] && [[ "${LOGS_WITH_SVCNAME:-0}" -gt 0 ]]; then
  pass "Logs with flat serviceName: $LOGS_WITH_SVCNAME (alternative path)"
elif [[ "${LOGS_WITH_SVC:-0}" -eq 0 ]]; then
  fail "Logs have neither resource.attributes.service.name nor serviceName"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 10 — Span metrics in Prometheus
# ═════════════════════════════════════════════════════════════════════════════
info "Step 10: Span metrics in Prometheus"

SPAN_SERIES=$(curl -s "$PROM_URL/api/v1/query?query=traces_span_metrics_calls_total" 2>/dev/null \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',{}).get('result',[])))" 2>/dev/null || echo "0")
[[ "${SPAN_SERIES:-0}" -gt 0 ]] \
  && pass "Span metric series in Prometheus: $SPAN_SERIES" \
  || fail "No span metrics (traces_span_metrics_calls_total) in Prometheus"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 11 — Data is actively flowing (optional, skip with --quick)
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$QUICK" -eq 0 ]]; then
  info "Step 11: Data growth check (20 s)"
  SPANS_T0=$(os_count "otel-v1-apm-span-000001")
  LOGS_T0=$(os_count "logs-otel-v1-000001")
  sleep 20
  SPANS_T1=$(os_count "otel-v1-apm-span-000001")
  LOGS_T1=$(os_count "logs-otel-v1-000001")

  SPAN_DELTA=$(( SPANS_T1 - SPANS_T0 ))
  LOG_DELTA=$(( LOGS_T1 - LOGS_T0 ))

  [[ "$SPAN_DELTA" -gt 0 ]] \
    && pass "Spans growing: +$SPAN_DELTA in 20 s" \
    || fail "No new spans in 20 s (pipeline may be stalled)"

  [[ "$LOG_DELTA" -gt 0 ]] \
    && pass "Logs growing: +$LOG_DELTA in 20 s" \
    || fail "No new logs in 20 s (pipeline may be stalled)"
else
  info "Step 11: Skipped (--quick mode)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Result: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
