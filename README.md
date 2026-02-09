# 🚀 Jimi IoT Gateway

> Gateway de recepção de dados IoT com infraestrutura como código, redes seguras e telemetria completa.
> Desafio técnico DevOps Pleno — Yuv.

[![Docker](https://img.shields.io/badge/Docker-20.10+-blue.svg)](https://www.docker.com/)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2.0+-blue.svg)](https://docs.docker.com/compose/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 📋 Índice

- [Arquitetura](#-arquitetura)
- [Pré-requisitos](#-pré-requisitos)
- [Início Rápido](#-início-rápido)
- [Configuração](#-configuração)
- [Endpoints da API](#-endpoints-da-api)
- [Observabilidade](#-observabilidade)
- [Segurança](#-segurança)
- [Troubleshooting](#-troubleshooting)
- [Estrutura do Projeto](#-estrutura-do-projeto)

## 🏗 Arquitetura

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    INTERNET                              │
                    └─────────────────────────┬───────────────────────────────┘
                                              │
                                              ▼
                    ┌─────────────────────────────────────────────────────────┐
                    │              JIMI CLOUD PLATFORM                         │
                    │         (Envia webhooks de dispositivos IoT)             │
                    └─────────────────────────┬───────────────────────────────┘
                                              │
                                              │ HTTPS (443)
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              FRONTEND NETWORK                                    │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                         NGINX (Proxy Reverso)                               │ │
│  │   • Terminação TLS                    • Rate Limiting                       │ │
│  │   • Validação de requisições          • Logging estruturado                 │ │
│  │   • Load Balancing                    • Health Checks                       │ │
│  └────────────────────────────────────────┬───────────────────────────────────┘ │
└───────────────────────────────────────────┼─────────────────────────────────────┘
                                            │
                                            │ HTTP (8000) - Interno
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              BACKEND NETWORK (Internal)                          │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                         BACKEND (FastAPI)                                   │ │
│  │   • /v1/telemetry    (POST)           • /metrics (Prometheus)               │ │
│  │   • /v1/alarms       (POST)           • /health  (Health Check)             │ │
│  │   • /v1/heartbeat    (POST)           • Logging estruturado (JSON)          │ │
│  └────────────────────────────────────────┬───────────────────────────────────┘ │
└───────────────────────────────────────────┼─────────────────────────────────────┘
                                            │
                                            │ Scrape / Push
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           MONITORING NETWORK                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │  PROMETHEUS  │    │    LOKI      │    │   GRAFANA    │    │ ALERTMANAGER │   │
│  │   :9090      │    │    :3100     │    │    :3000     │    │    :9093     │   │
│  │   Métricas   │    │    Logs      │    │  Dashboards  │    │   Alertas    │   │
│  └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘   │
│         ▲                   ▲                                                    │
│         │                   │                                                    │
│  ┌──────┴───────────────────┴────────────────────────────────────────────────┐  │
│  │                           PROMTAIL                                         │  │
│  │                   (Coleta de logs do Docker)                               │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## 📦 Pré-requisitos

- **Docker** >= 20.10
- **Docker Compose** >= 2.0
- **OpenSSL** (para geração de certificados)
- **curl** (para testes)

```bash
# Verificar versões
docker --version
docker compose version
openssl version
```

## 🚀 Início Rápido

### 1. Clonar e Configurar

```bash
# Navegar para o diretório do projeto
cd teste-tecnico-devops

# Copiar arquivo de ambiente (se necessário)
cp .env.example .env

# Editar configurações (opcional)
nano .env
```

### 2. Gerar Certificados TLS

```bash
# Gerar certificados auto-assinados
./certs/generate-certs.sh

# Ou especificar domínio e validade
./certs/generate-certs.sh api.jimi.local 365
```

### 3. Configurar /etc/hosts

```bash
# Adicionar entrada no hosts
echo "127.0.0.1 api.jimi.local" | sudo tee -a /etc/hosts
```

### 4. Iniciar a Stack

```bash
# Subir todos os serviços
docker compose up -d

# Verificar status
docker compose ps

# Verificar logs
docker compose logs -f
```

### 5. Validar a Instalação

```bash
# Health check
curl -k https://api.jimi.local/health

# Testar endpoint de telemetria
curl -k -X POST https://api.jimi.local/v1/telemetry \
  -H "Content-Type: application/json" \
  -H "X-Jimi-Token: <seu_token>" \
  -d '{
    "device_id": "JIMI-TEST-001",
    "timestamp": "2025-02-06T12:00:00Z",
    "latitude": -23.5505,
    "longitude": -46.6333,
    "speed": 60.5,
    "battery": 85.0
  }'
```

Use o mesmo valor configurado em `WEBHOOK_TOKEN` no `.env`.

## ⚙️ Configuração

### Variáveis de Ambiente (.env)

| Variável | Descrição | Padrão |
|----------|-----------|--------|
| `APP_ENV` | Ambiente da aplicação | `production` |
| `LOG_LEVEL` | Nível de log | `INFO` |
| `STACK_MODE` | Seleciona a stack a iniciar (`local` ou `iothub`) | `local` |
| `WEBHOOK_TOKEN` | Token de validação da origem | `JIMI_WEBHOOK_TOKEN_2025` |
| `NGINX_HTTP_PORT` | Porta HTTP do Nginx | `80` |
| `NGINX_HTTPS_PORT` | Porta HTTPS do Nginx | `443` |
| `GRAFANA_PORT` | Porta do Grafana (se exposta manualmente) | `3000` |
| `GRAFANA_ADMIN_PASSWORD` | Senha do admin Grafana | `JimiIoT@2025!` |
| `PROMETHEUS_PORT` | Porta do Prometheus (se exposta manualmente) | `9090` |
| `LOKI_PORT` | Porta do Loki (se exposta manualmente) | `3100` |

**Stack mode:**  
`local` inicia o gateway (backend FastAPI + observabilidade).  
`iothub` inicia apenas a stack fornecida em `iothub/` (sem os endpoints do gateway).

## 🔌 Endpoints da API

### Webhooks

| Endpoint | Método | Descrição |
|----------|--------|-----------|
| `/v1/telemetry` | POST | Dados de telemetria GPS/sensores |
| `/v1/alarms` | POST | Alertas e alarmes |
| `/v1/heartbeat` | POST | Sinais de vida dos dispositivos |

**Observação:** todos os endpoints `/v1/*` exigem o header `X-Jimi-Token`.

### Sistema

| Endpoint | Método | Descrição |
|----------|--------|-----------|
| `/health` | GET | Health check |
| `/ready` | GET | Readiness check |
| `/metrics` | GET | Métricas Prometheus |

### Exemplos de Payloads

<details>
<summary><b>Telemetria</b></summary>

```json
{
  "device_id": "JIMI-001",
  "timestamp": "2025-02-06T12:00:00Z",
  "latitude": -23.5505,
  "longitude": -46.6333,
  "speed": 60.5,
  "altitude": 800,
  "heading": 180,
  "satellites": 12,
  "battery": 85.0,
  "ignition": true,
  "data": {
    "odometer": 123456,
    "fuel_level": 75
  }
}
```
</details>

<details>
<summary><b>Alarme</b></summary>

```json
{
  "device_id": "JIMI-001",
  "alarm_type": "overspeed",
  "severity": "high",
  "timestamp": "2025-02-06T12:00:00Z",
  "message": "Velocidade excedeu 120 km/h",
  "latitude": -23.5505,
  "longitude": -46.6333
}
```
</details>

<details>
<summary><b>Heartbeat</b></summary>

```json
{
  "device_id": "JIMI-001",
  "timestamp": "2025-02-06T12:00:00Z",
  "status": "online",
  "battery": 90.0,
  "signal_strength": 75,
  "firmware_version": "1.2.3"
}
```
</details>

## 📊 Observabilidade

### Acessar Dashboards

Por padrão, os serviços de monitoramento **não expõem portas no host**. Isso atende ao requisito de não expor serviços diretamente.

Para consultas rápidas via CLI, use o backend como ponto de acesso interno:

```bash
# Prometheus (exemplo)
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query?query=up"

# Loki (exemplo)
docker compose exec backend curl -s "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="backend"} |= "error"' \
  --data-urlencode 'limit=20'
```

Se precisar acessar a UI do Grafana/Prometheus em ambiente local, exponha as portas **temporariamente** no `docker-compose.yml`.

### Métricas Disponíveis

```promql
# Webhooks recebidos por endpoint
jimi_webhooks_received_total{endpoint="telemetry"}

# Taxa de erro HTTP
sum(rate(jimi_http_errors_total[5m])) / sum(rate(jimi_http_requests_total[5m]))

# Latência P95
histogram_quantile(0.95, sum(rate(jimi_request_latency_ms_bucket[5m])) by (le))

# Conexões ativas
jimi_active_connections
```

### Alertas Configurados

- **BackendDown**: Backend não está respondendo
- **HighErrorRate**: Taxa de erro > 5%
- **CriticalErrorRate**: Taxa de erro > 10%
- **HighLatencyP95**: Latência P95 > 500ms
- **NoWebhooksReceived**: Nenhum webhook em 15min

## 🔒 Segurança

### Isolamento de Rede

- **Frontend Network**: Apenas Nginx exposto
- **Backend Network**: Rede interna (internal: true)
- **Monitoring Network**: Stack de observabilidade

### Medidas Implementadas

- ✅ Backend não exposto diretamente
- ✅ TLS 1.2/1.3 no proxy reverso
- ✅ Rate limiting (100 req/s)
- ✅ Validação de Content-Type
- ✅ Validação de origem via `X-Jimi-Token`
- ✅ Headers de segurança (HSTS, X-Frame-Options, etc.)
- ✅ Containers rodando como non-root
- ✅ Logs estruturados para auditoria

## 🔧 Troubleshooting

Consulte o guia completo em [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

### Comandos Úteis

```bash
# Status dos containers
docker compose ps

# Logs em tempo real
docker compose logs -f backend

# Verificar métricas (via rede interna)
docker compose exec backend curl -s "http://prometheus:9090/api/v1/query?query=up"

# Consultar logs no Loki (via rede interna)
docker compose exec backend curl -s "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="backend"}' \
  --data-urlencode 'limit=10'

# Reiniciar um serviço
docker compose restart backend

# Rebuild do backend
docker compose build backend && docker compose up -d backend
```

## 📁 Estrutura do Projeto

```
teste-tecnico-devops/
├── docker-compose.yml          # Orquestração de containers
├── .env                        # Variáveis de ambiente
├── .env.example                # Exemplo de configuração
├── README.md                   # Documentação principal
│
├── backend/                    # Aplicação FastAPI
│   ├── Dockerfile
│   ├── main.py
│   └── requirements.txt
│
├── nginx/                      # Proxy Reverso
│   ├── conf/
│   │   ├── nginx.conf
│   │   ├── default.conf
│   │   └── proxy_params.conf
│   └── logs/                   # Logs do Nginx
│
├── certs/                      # Certificados TLS
│   ├── generate-certs.sh
│   ├── server.crt
│   └── server.key
│
├── prometheus/                 # Configuração Prometheus
│   ├── prometheus.yml
│   ├── alerts.yml
│   └── alertmanager.yml
│
├── grafana/                    # Configuração Grafana
│   ├── provisioning/
│   │   ├── datasources/
│   │   └── dashboards/
│   └── dashboards/
│       └── grafana-dashboard-jimi-iot.json
│
├── loki/                       # Configuração Loki
│   └── loki-config.yml
│
├── promtail/                   # Configuração Promtail
│   └── promtail-config.yml
│
└── docs/                       # Documentação adicional
    └── TROUBLESHOOTING.md
```

## 🧪 Testes

```bash
# Testes funcionais dos endpoints (execute na raiz do projeto)
./scripts/test-endpoints.sh

# Se estiver em outro diretório:
# WEBHOOK_TOKEN=JIMI_WEBHOOK_TOKEN_2025 ./scripts/test-endpoints.sh

# Script de teste de carga simples
for i in {1..100}; do
  curl -sk -X POST https://api.jimi.local/v1/telemetry \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"LOAD-TEST-$i\",\"timestamp\":\"$(date -Iseconds)\",\"latitude\":-23.55,\"longitude\":-46.63}" &
done
wait
echo "Teste concluído!"
```

## 📝 Licença

Este projeto é parte de um desafio técnico para a posição de DevOps Pleno.

---

**Desenvolvido com ❤️ para o desafio Jimi IoT Gateway**
# devops-tech-challenge-yuv
