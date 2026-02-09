# 🔧 Guia de Troubleshooting

> Diagnóstico e resolução de problemas no Jimi IoT Gateway

## 📋 Índice

- [Cenário: Dados Atrasando](#-cenário-dados-da-jimi-cloud-começam-a-atrasar)
- [Checklist de Diagnóstico](#-checklist-de-diagnóstico)
- [Métricas-Chave](#-métricas-chave)
- [Estratégias de Resolução](#-estratégias-de-resolução)
- [Comandos de Troubleshooting](#-comandos-de-troubleshooting)
- [Runbooks](#-runbooks)

---

## 🚨 Cenário: Dados da Jimi Cloud Começam a Atrasar

### Sintomas

- Dispositivos IoT não atualizam posição em tempo real
- Alertas chegam com atraso
- Heartbeats não são processados dentro do SLA

### Diagnóstico Sistemático

```
┌─────────────────────────────────────────────────────────────────────┐
│                      FLUXO DE DIAGNÓSTICO                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. VERIFICAR SAÚDE DOS CONTAINERS                                   │
│     └─► docker compose ps                                            │
│         └─► Algum container está "unhealthy" ou "restarting"?       │
│                                                                      │
│  2. VERIFICAR RECURSOS (CPU/RAM)                                     │
│     └─► docker stats                                                 │
│         └─► CPU > 80%? Memória > 90%?                               │
│                                                                      │
│  3. ANALISAR TAXA DE ERRO HTTP                                       │
│     └─► Prometheus: rate(jimi_http_errors_total[5m])                │
│         └─► Taxa > 5%? Investigar logs                              │
│                                                                      │
│  4. VERIFICAR LATÊNCIA                                               │
│     └─► Prometheus: histogram_quantile(0.95, ...)                   │
│         └─► P95 > 500ms? Gargalo identificado                       │
│                                                                      │
│  5. ANALISAR LOGS                                                    │
│     └─► Grafana/Loki: {job="backend"} |= "error"                    │
│         └─► Identificar padrão de erros                             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## ✅ Checklist de Diagnóstico

### 1. Verificar Saúde dos Containers

```bash
# Status de todos os containers
docker compose ps

# Saída esperada (todos "healthy"):
# NAME              STATUS                   PORTS
# jimi-nginx        Up (healthy)             0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
# jimi-backend      Up (healthy)             8000/tcp
# jimi-prometheus   Up (healthy)             0.0.0.0:9090->9090/tcp
# jimi-grafana      Up (healthy)             0.0.0.0:3000->3000/tcp
# jimi-loki         Up (healthy)             0.0.0.0:3100->3100/tcp
```

### 2. Monitorar CPU e Memória

```bash
# Estatísticas em tempo real
docker stats --no-stream

# Métricas detalhadas
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

**Thresholds de Alerta:**
| Métrica | Warning | Critical |
|---------|---------|----------|
| CPU | > 70% | > 90% |
| Memória | > 80% | > 95% |

### 3. Analisar Taxa de Erro HTTP

**Nota:** Prometheus e Loki não expõem portas no host. Use o backend como ponto de acesso interno com `docker compose exec backend`.

```bash
# Via Prometheus API
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query" \
  --data-urlencode 'query=sum(rate(jimi_http_errors_total[5m])) / sum(rate(jimi_http_requests_total[5m])) * 100' \
  | jq '.data.result[0].value[1]'

# Via endpoint de métricas direto
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query?query=jimi_http_errors_total" | jq
```

### 4. Verificar Latência de Rede

```bash
# Latência P95 por endpoint
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query" \
  --data-urlencode 'query=histogram_quantile(0.95, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le, endpoint))' \
  | jq '.data.result[] | {endpoint: .metric.endpoint, p95_ms: .value[1]}'

# Latência P99
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query" \
  --data-urlencode 'query=histogram_quantile(0.99, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le))' \
  | jq '.data.result[0].value[1]'
```

---

## 📊 Métricas-Chave

### Requisições por Segundo (RPS)

```promql
# RPS total
sum(rate(jimi_http_requests_total[1m]))

# RPS por endpoint
sum(rate(jimi_http_requests_total[1m])) by (endpoint)

# RPS de sucesso vs erro
sum(rate(jimi_http_requests_total{status=~"2.."}[1m]))  # Sucesso
sum(rate(jimi_http_errors_total[1m]))                    # Erro
```

### Latência (P50, P95, P99)

```promql
# P50 (mediana)
histogram_quantile(0.50, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le))

# P95
histogram_quantile(0.95, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le))

# P99
histogram_quantile(0.99, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le))
```

### Taxa de Erro HTTP 5xx

```promql
# Porcentagem de erros
(sum(rate(jimi_http_errors_total{status=~"5.."}[5m])) / sum(rate(jimi_http_requests_total[5m]))) * 100

# Erros por endpoint
sum(rate(jimi_http_errors_total[5m])) by (endpoint, status)
```

### Tamanho da Fila de Processamento

```promql
# Conexões ativas (proxy para fila)
jimi_active_connections

# Webhooks pendentes (se implementado)
# jimi_webhooks_queue_size
```

---

## 🛠 Estratégias de Resolução

### 1. Aumentar Recursos (Vertical Scaling)

```yaml
# docker-compose.yml - Adicionar limites
services:
  backend:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 256M
```

```bash
# Aplicar mudanças
docker compose up -d backend
```

### 2. Adicionar Réplicas (Horizontal Scaling)

```yaml
# docker-compose.yml
services:
  backend:
    deploy:
      replicas: 3
```

```bash
# Escalar manualmente
docker compose up -d --scale backend=3
```

### 3. Implementar Circuit Breaker

**No Nginx:**
```nginx
# nginx/conf/default.conf
upstream backend {
    server backend:8000 max_fails=3 fail_timeout=30s;
    # Se houver réplicas:
    # server backend-2:8000 max_fails=3 fail_timeout=30s;
    # server backend-3:8000 max_fails=3 fail_timeout=30s;
}
```

### 4. Cache no Nginx

```nginx
# nginx/conf/default.conf
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=api_cache:10m max_size=100m inactive=60m;

location /v1/telemetry {
    # Cache para respostas idênticas
    proxy_cache api_cache;
    proxy_cache_valid 200 1s;
    proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
    
    proxy_pass http://backend;
}
```

### 5. Rate Limiting Avançado

```nginx
# nginx/conf/nginx.conf
# Rate limit por IP
limit_req_zone $binary_remote_addr zone=per_ip:10m rate=10r/s;

# Rate limit por device_id (requer Lua ou log parsing)
# limit_req_zone $arg_device_id zone=per_device:10m rate=100r/s;

# Aplicar no location
location /v1/telemetry {
    limit_req zone=per_ip burst=20 nodelay;
    limit_req_status 429;
    # ...
}
```

---

## 💻 Comandos de Troubleshooting

### Consultar Logs

```bash
# Logs do backend em tempo real
docker compose logs -f backend

# Últimas 100 linhas com timestamp
docker compose logs --tail=100 -t backend

# Filtrar erros
docker compose logs backend 2>&1 | grep -i error

# Logs do Nginx
docker compose logs nginx

# Logs de todos os serviços
docker compose logs -f
```

### Queries Prometheus

```bash
# Verificar targets ativos
docker compose exec backend curl -s "http://prometheus:9090/api/v1/targets" | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Listar todas as métricas disponíveis
docker compose exec backend curl -s "http://prometheus:9090/api/v1/label/__name__/values" | jq '.data[]' | grep jimi

# Query de range (últimas 5 minutos)
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query_range" \
  --data-urlencode 'query=rate(jimi_webhooks_received_total[1m])' \
  --data-urlencode 'start='$(date -d '5 minutes ago' +%s) \
  --data-urlencode 'end='$(date +%s) \
  --data-urlencode 'step=15s' | jq
```

### Queries Loki

```bash
# Logs de erro do backend
docker compose exec backend curl -s "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="backend"} |= "error"' \
  --data-urlencode 'limit=50' | jq '.data.result[].values[]'

# Logs por device_id específico
docker compose exec backend curl -s "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="backend"} |= "JIMI-001"' \
  --data-urlencode 'limit=20' | jq

# Contar erros por minuto
docker compose exec backend curl -s "http://loki:3100/loki/api/v1/query" \
  --data-urlencode 'query=count_over_time({job="backend"} |= "error" [1m])' | jq
```

### Analisar Healthchecks

```bash
# Status detalhado de um container
docker inspect jimi-backend --format='{{json .State.Health}}' | jq

# Verificar health de todos os containers
for c in $(docker compose ps -q); do
  name=$(docker inspect $c --format='{{.Name}}')
  health=$(docker inspect $c --format='{{.State.Health.Status}}' 2>/dev/null || echo "no healthcheck")
  echo "$name: $health"
done
```

---

## 📖 Runbooks

### Runbook 1: Backend Não Responde

```bash
#!/bin/bash
# runbook-backend-down.sh

echo "🔍 Diagnóstico: Backend Down"

# 1. Verificar status
echo "1. Status do container:"
docker compose ps backend

# 2. Verificar logs recentes
echo -e "\n2. Últimos logs:"
docker compose logs --tail=50 backend

# 3. Verificar recursos
echo -e "\n3. Uso de recursos:"
docker stats --no-stream jimi-backend

# 4. Tentar restart
echo -e "\n4. Tentando restart..."
docker compose restart backend

# 5. Verificar novamente
sleep 10
echo -e "\n5. Status após restart:"
docker compose ps backend

# 6. Health check
echo -e "\n6. Health check:"
docker compose exec backend curl -s http://localhost:8000/health || echo "FALHA"
```

### Runbook 2: Alta Latência

```bash
#!/bin/bash
# runbook-high-latency.sh

echo "🔍 Diagnóstico: Alta Latência"

# 1. Verificar P95 atual
echo "1. Latência P95:"
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query" \
  --data-urlencode 'query=histogram_quantile(0.95, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le))' \
  | jq '.data.result[0].value[1]'

# 2. Verificar recursos
echo -e "\n2. Uso de recursos:"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}"

# 3. Verificar conexões ativas
echo -e "\n3. Conexões ativas:"
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query?query=jimi_active_connections" \
  | jq '.data.result[0].value[1]'

# 4. RPS atual
echo -e "\n4. RPS atual:"
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query" \
  --data-urlencode 'query=sum(rate(jimi_http_requests_total[1m]))' \
  | jq '.data.result[0].value[1]'

# 5. Recomendações
echo -e "\n📋 Recomendações:"
echo "   - Se CPU > 70%: Considerar escalar horizontalmente"
echo "   - Se Memória > 80%: Aumentar limites ou verificar memory leaks"
echo "   - Se RPS muito alto: Verificar rate limiting"
```

### Runbook 3: Disco Cheio (Logs/Métricas)

```bash
#!/bin/bash
# runbook-disk-full.sh

echo "🔍 Diagnóstico: Espaço em Disco"

# 1. Verificar uso de disco
echo "1. Uso de disco:"
df -h /var/lib/docker

# 2. Volumes Docker
echo -e "\n2. Volumes Docker:"
docker system df -v

# 3. Logs grandes
echo -e "\n3. Tamanho dos logs:"
du -sh /var/lib/docker/containers/*/

# 4. Limpar logs (cuidado!)
echo -e "\n4. Para limpar logs antigos:"
echo "   docker compose logs --no-log-prefix backend | tail -n 10000 > /tmp/backend-recent.log"
echo "   truncate -s 0 /var/lib/docker/containers/<container-id>/*-json.log"

# 5. Prune de recursos não utilizados
echo -e "\n5. Para limpar recursos não utilizados:"
echo "   docker system prune -a --volumes"
```

---

## 📈 Dashboards de Referência

### Grafana - Queries Úteis

**Webhook Success Rate:**
```promql
(sum(rate(jimi_webhooks_received_total{status="success"}[5m])) / sum(rate(jimi_webhooks_received_total[5m]))) * 100
```

**Throughput por Endpoint:**
```promql
sum(rate(jimi_webhooks_received_total[1m])) by (endpoint)
```

**Error Budget Consumption:**
```promql
1 - (sum(rate(jimi_http_requests_total{status=~"2.."}[24h])) / sum(rate(jimi_http_requests_total[24h])))
```

---

## 📞 Escalação

| Nível | Critério | Ação |
|-------|----------|------|
| **L1** | Taxa de erro < 5%, Latência P95 < 500ms | Monitorar |
| **L2** | Taxa de erro 5-10%, Latência P95 500ms-1s | Investigar + Notificar |
| **L3** | Taxa de erro > 10%, Latência P95 > 1s | Incidente + Escalar |
| **Critical** | Backend down, Perda de dados | War room imediato |

---

**Última atualização:** Fevereiro 2025
