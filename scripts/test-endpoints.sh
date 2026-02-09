#!/bin/bash
# ===========================================
# Script de Teste dos Endpoints
# Jimi IoT Gateway
# ===========================================

set -e

BASE_URL="${BASE_URL:-https://api.jimi.local}"
CURL_OPTS="-sk"

# Carregar variáveis do .env (se existir)
if [ -f ".env" ]; then
  set -a
  . ./.env
  set +a
fi

WEBHOOK_TOKEN="${WEBHOOK_TOKEN:-}"
AUTH_HEADER="X-Jimi-Token: ${WEBHOOK_TOKEN}"
STACK_MODE="${STACK_MODE:-local}"

echo "🧪 Testando Jimi IoT Gateway"
echo "   Base URL: $BASE_URL"
echo "=========================================="

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }
warn() { echo -e "${YELLOW}⚠ WARN${NC}: $1"; }

if [ -z "$WEBHOOK_TOKEN" ]; then
  warn "WEBHOOK_TOKEN não definido. Defina no .env para que os testes de webhook passem."
fi

if [ "$STACK_MODE" = "iothub" ]; then
  warn "STACK_MODE=iothub: endpoints do gateway não estão disponíveis. Testes ignorados."
  exit 0
fi

# ===========================================
# Health Checks
# ===========================================
echo -e "\n📋 Health Checks"
echo "-------------------------------------------"

# Health endpoint
response=$(curl $CURL_OPTS -o /dev/null -w "%{http_code}" "$BASE_URL/health")
[[ "$response" == "200" ]] && pass "GET /health (HTTP $response)" || fail "GET /health (HTTP $response)"

# ===========================================
# Webhook Endpoints
# ===========================================
echo -e "\n📡 Webhook Endpoints"
echo "-------------------------------------------"

# Telemetry
response=$(curl $CURL_OPTS -X POST "$BASE_URL/v1/telemetry" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d '{
    "device_id": "TEST-001",
    "timestamp": "2025-02-06T12:00:00Z",
    "latitude": -23.5505,
    "longitude": -46.6333,
    "speed": 60.5,
    "battery": 85.0
  }' \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "200" ]] && pass "POST /v1/telemetry (HTTP $response)" || fail "POST /v1/telemetry (HTTP $response)"

# Alarms
response=$(curl $CURL_OPTS -X POST "$BASE_URL/v1/alarms" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d '{
    "device_id": "TEST-001",
    "alarm_type": "overspeed",
    "severity": "high",
    "timestamp": "2025-02-06T12:00:00Z",
    "message": "Test alarm"
  }' \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "200" ]] && pass "POST /v1/alarms (HTTP $response)" || fail "POST /v1/alarms (HTTP $response)"

# Heartbeat
response=$(curl $CURL_OPTS -X POST "$BASE_URL/v1/heartbeat" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d '{
    "device_id": "TEST-001",
    "timestamp": "2025-02-06T12:00:00Z",
    "status": "online",
    "battery": 90.0
  }' \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "200" ]] && pass "POST /v1/heartbeat (HTTP $response)" || fail "POST /v1/heartbeat (HTTP $response)"

# ===========================================
# Validation Tests
# ===========================================
echo -e "\n🔒 Validation Tests"
echo "-------------------------------------------"

# Invalid JSON
response=$(curl $CURL_OPTS -X POST "$BASE_URL/v1/telemetry" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d 'invalid json' \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "400" ]] && pass "Rejeita JSON inválido (HTTP $response)" || warn "JSON inválido retornou HTTP $response (esperado 400)"

# Missing required field
response=$(curl $CURL_OPTS -X POST "$BASE_URL/v1/telemetry" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d '{"timestamp": "2025-02-06T12:00:00Z"}' \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "400" ]] && pass "Rejeita payload incompleto (HTTP $response)" || warn "Payload incompleto retornou HTTP $response (esperado 400)"

# Wrong Content-Type
response=$(curl $CURL_OPTS -X POST "$BASE_URL/v1/telemetry" \
  -H "Content-Type: text/plain" \
  -H "$AUTH_HEADER" \
  -d '{"device_id": "TEST", "timestamp": "2025-02-06T12:00:00Z"}' \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "415" ]] && pass "Rejeita Content-Type inválido (HTTP $response)" || warn "Content-Type inválido retornou HTTP $response (esperado 415)"

# Wrong Method
response=$(curl $CURL_OPTS -X GET "$BASE_URL/v1/telemetry" \
  -o /dev/null -w "%{http_code}")
[[ "$response" == "405" ]] && pass "Rejeita método GET (HTTP $response)" || warn "Método GET retornou HTTP $response (esperado 405)"

# ===========================================
# Metrics
# ===========================================
echo -e "\n📊 Metrics"
echo "-------------------------------------------"

response=$(curl $CURL_OPTS "$BASE_URL/metrics" -o /dev/null -w "%{http_code}")
[[ "$response" == "200" ]] && pass "GET /metrics (HTTP $response)" || fail "GET /metrics (HTTP $response)"

metrics=$(curl $CURL_OPTS "$BASE_URL/metrics")
echo "$metrics" | grep -q "jimi_webhooks_received_total" && pass "Métrica jimi_webhooks_received_total presente" || warn "Métrica jimi_webhooks_received_total não encontrada"
echo "$metrics" | grep -q "jimi_request_latency_ms" && pass "Métrica jimi_request_latency_ms presente" || warn "Métrica jimi_request_latency_ms não encontrada"

# ===========================================
# Summary
# ===========================================
echo -e "\n=========================================="
echo "✅ Todos os testes básicos passaram!"
echo ""
echo "📊 Dashboards:"
echo "   Grafana/Prometheus/Loki não expõem portas no host por padrão."
