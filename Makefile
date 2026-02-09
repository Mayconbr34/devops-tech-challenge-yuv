# ===========================================
# Jimi IoT Gateway - Makefile
# ===========================================

.PHONY: help build up down restart logs status test clean certs

# Variáveis
STACK_MODE ?= $(shell awk -F= '/^STACK_MODE=/{print $$2}' .env)
STACK_MODE ?= local
ifeq ($(STACK_MODE),iothub)
COMPOSE_FILE := iothub/docker-compose.yml
else
COMPOSE_FILE := docker-compose.yml
endif
COMPOSE = docker compose -f $(COMPOSE_FILE)
CURL = curl -sk
WEBHOOK_TOKEN ?= $(shell awk -F= '/^WEBHOOK_TOKEN=/{print $$2}' .env)
AUTH_HEADER = -H "X-Jimi-Token: $(WEBHOOK_TOKEN)"

# Cores
GREEN  := $(shell tput -Txterm setaf 2)
YELLOW := $(shell tput -Txterm setaf 3)
RESET  := $(shell tput -Txterm sgr0)

## Ajuda
help: ## Mostra esta ajuda
	@echo ''
	@echo '${GREEN}Jimi IoT Gateway${RESET}'
	@echo ''
	@echo 'Uso:'
	@echo '  ${YELLOW}make${RESET} ${GREEN}<target>${RESET}'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  ${YELLOW}%-15s${RESET} %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## Build
build: ## Build das imagens Docker
	$(COMPOSE) build

## Up
up: ## Inicia todos os serviços
	$(COMPOSE) up -d

## Down
down: ## Para todos os serviços
	$(COMPOSE) down

## Restart
restart: ## Reinicia todos os serviços
	$(COMPOSE) restart

## Logs
logs: ## Mostra logs de todos os serviços
	$(COMPOSE) logs -f

## Status
status: ## Mostra status dos containers
	$(COMPOSE) ps
	@echo ""
	@echo "Health checks:"
	@$(CURL) https://api.jimi.local/health 2>/dev/null && echo " ✓ Backend OK" || echo " ✗ Backend FAIL"

## Test
test: ## Executa testes dos endpoints
	@chmod +x scripts/test-endpoints.sh
	@./scripts/test-endpoints.sh

## Certs
certs: ## Gera certificados TLS
	@chmod +x certs/generate-certs.sh
	@./certs/generate-certs.sh

## Clean
clean: ## Remove containers, volumes e imagens
	$(COMPOSE) down -v --rmi local
	docker system prune -f

## Shell
shell-backend: ## Acessa shell do backend
	$(COMPOSE) exec backend /bin/sh

shell-nginx: ## Acessa shell do nginx
	$(COMPOSE) exec nginx /bin/sh

## Métricas
metrics: ## Mostra métricas do backend
	@$(CURL) https://api.jimi.local/metrics | grep jimi_

## Prometheus
prom-targets: ## Mostra targets do Prometheus
	@$(COMPOSE) exec -T backend curl -s "http://prometheus:9090/api/v1/targets" | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

prom-alerts: ## Mostra alertas ativos
	@$(COMPOSE) exec -T backend curl -s "http://prometheus:9090/api/v1/alerts" | jq '.data.alerts'

## Grafana
grafana-open: ## Abre Grafana no navegador
	@echo "Grafana não exposta no host por padrão. Exponha as portas temporariamente se precisar acessar."

## Load Test
load-test: ## Executa teste de carga simples (100 requests)
	@echo "Enviando 100 requisições..."
	@for i in $$(seq 1 100); do \
		$(CURL) -X POST https://api.jimi.local/v1/telemetry \
			-H "Content-Type: application/json" \
			$(AUTH_HEADER) \
			-d "{\"device_id\":\"LOAD-$$i\",\"timestamp\":\"$$(date -Iseconds)\",\"latitude\":-23.55,\"longitude\":-46.63}" & \
	done; wait
	@echo "Teste concluído!"

## Hosts
hosts-add: ## Adiciona entrada no /etc/hosts (requer sudo)
	@grep -q "api.jimi.local" /etc/hosts || echo "127.0.0.1 api.jimi.local" | sudo tee -a /etc/hosts
	@echo "Entrada adicionada: 127.0.0.1 api.jimi.local"

## Init
init: certs hosts-add build up ## Inicialização completa (certs + hosts + build + up)
	@echo ""
	@echo "✅ Stack inicializada!"
	@echo ""
	@echo "URLs:"
	@echo "  API:         https://api.jimi.local"
	@echo "  Observabilidade: não exposta no host por padrão"
